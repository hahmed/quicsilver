# frozen_string_literal: true

require_relative 'http3/request_encoder'
require_relative 'http3/response_parser'

module Quicsilver
  class Client
    attr_reader :hostname, :port, :unsecure, :connection_timeout

    def initialize(hostname, port = 4433, options = {})
      @hostname = hostname
      @port = port
      @unsecure = options.fetch(:unsecure, true)
      @connection_timeout = options.fetch(:connection_timeout, 5000)

      @connection_data = nil
      @connected = false
      @connection_start_time = nil

      # Instance-level response tracking
      @response_buffers = {}  # stream_id => accumulated data
      @response_complete = {} # stream_id => parsed response
      @mutex = Mutex.new
    end

    # Called directly by C extension via process_events
    # C extension routes to this instance based on client_obj stored in connection context
    def handle_stream_event(stream_id, event, data)
      # Client only handles RECEIVE events (responses from server)
      return unless ["RECEIVE", "RECEIVE_FIN"].include?(event)

      @mutex.synchronize do
        case event
        when "RECEIVE"
          # Buffer incoming response data
          @response_buffers[stream_id] ||= ""
          @response_buffers[stream_id] += data
        when "RECEIVE_FIN"
          # Extract stream handle (first 8 bytes) and actual data
          stream_handle = data[0, 8].unpack1('Q') if data.bytesize >= 8
          actual_data = data[8..-1] || ""

          # Get all buffered data
          full_data = (@response_buffers[stream_id] || "") + actual_data
          @response_buffers.delete(stream_id)

          # Parse HTTP3 response
          parser = Quicsilver::HTTP3::ResponseParser.new(full_data)
          parser.parse

          # Store complete response with body as string
          @response_complete[stream_id] = {
            status: parser.status,
            headers: parser.headers,
            body: parser.body.read
          }
        end
      end
    rescue => e
      puts "❌ Ruby: Error handling client stream: #{e.class} - #{e.message}"
      puts e.backtrace.first(5)
    end
    
    def connect
      raise Error, "Already connected" if @connected

      # Initialize MSQUIC if not already done
      result = Quicsilver.open_connection
      
      # Create configuration
      config = Quicsilver.create_configuration(@unsecure)
      raise ConnectionError, "Failed to create configuration" if config.nil?

      # Create connection (returns [handle, context])
      # Pass self so C extension can route callbacks to this instance
      @connection_data = Quicsilver.create_connection(self)
      raise ConnectionError, "Failed to create connection" if @connection_data.nil?
      
      connection_handle = @connection_data[0]
      context_handle = @connection_data[1]
      
      # Start the connection
      success = Quicsilver.start_connection(connection_handle, config, @hostname, @port)
      unless success
        Quicsilver.close_configuration(config)
        cleanup_failed_connection
        raise ConnectionError, "Failed to start connection"
      end

      # Wait for connection to establish or fail
      result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)

      if result.key?("error")
        error_status = result["status"]
        error_code = result["code"]
        Quicsilver.close_configuration(config)
        cleanup_failed_connection
        error_msg = "Connection failed with status: 0x#{error_status.to_s(16)}, code: #{error_code}"
        raise ConnectionError, error_msg
      elsif result.key?("timeout")
        Quicsilver.close_configuration(config)
        cleanup_failed_connection
        error_msg = "Connection timed out after #{@connection_timeout}ms"
        raise TimeoutError, error_msg
      end
      
      @connected = true
      @connection_start_time = Time.now

      send_control_stream

      # Clean up config since connection is established
      Quicsilver.close_configuration(config)
    rescue => e
      cleanup_failed_connection
      
      if e.is_a?(ConnectionError) || e.is_a?(TimeoutError)
        raise e
      else
        raise ConnectionError, "Connection failed: #{e.message}"
      end
    end
    
    def disconnect
      return unless @connected || @connection_data

      begin
        if @connection_data
          Quicsilver.close_connection_handle(@connection_data)
          @connection_data = nil
        end
      rescue
        # Ignore disconnect errors
      ensure
        @connected = false
        @connection_start_time = nil

        # Clean up any remaining response buffers
        @mutex.synchronize do
          @response_buffers.clear
          @response_complete.clear
        end
      end
    end
    
    def connected?
      return false unless @connected && @connection_data

      # Get connection status from the C extension
      context_handle = @connection_data[1]
      info = Quicsilver.connection_status(context_handle)
      if info && info.key?("connected")
        is_connected = info["connected"] && !info["failed"]
        
        # If C extension says we're disconnected, update our state
        if !is_connected && @connected
          @connected = false
        end
        
        is_connected
      else
        # If we can't get status, assume disconnected
        if @connected
          @connected = false
        end
        false
      end
    rescue
      # If there's an error checking status, assume disconnected
      if @connected
        @connected = false
      end
      false
    end
    
    def connection_info
      base_info = if @connection_data
        begin
          context_handle = @connection_data[1]
          Quicsilver.connection_status(context_handle) || {}
        rescue
          {}
        end
      else
        {}
      end
      
      base_info.merge({
        hostname: @hostname,
        port: @port,
        uptime: connection_uptime
      })
    end
    
    def connection_uptime
      return 0 unless @connection_start_time
      Time.now - @connection_start_time
    end

    def send_request(method, path, headers: {}, body: nil)
      raise Error, "Not connected" unless @connected

      request = Quicsilver::HTTP3::RequestEncoder.new(
        method: method,
        path: path,
        scheme: 'https',
        authority: "#{@hostname}:#{@port}",
        headers: headers,
        body: body
      )

      stream = open_stream
      unless stream
        raise Error, "Failed to open stream"
      end

      # Send data with FIN flag
      result = Quicsilver.send_stream(stream, request.encode, true)

      unless result
        raise Error, "Failed to send request"
      end

      # Return stream handle for tracking
      # Note: We don't have stream_id yet, it will come via callback
      stream
    end

    def receive_response(timeout: 5000)
      raise Error, "Not connected" unless @connected

      start = Time.now
      response = nil

      loop do
        # Process events - C extension will route to this instance
        Quicsilver.process_events

        # Check for completed responses
        @mutex.synchronize do
          # Find any completed response (simple approach - gets first available)
          stream_id, resp = @response_complete.first
          if resp
            response = resp
            @response_complete.delete(stream_id)
          end
        end

        break if response

        # Timeout check
        elapsed = (Time.now - start) * 1000
        if elapsed > timeout
          raise TimeoutError, "Response timeout after #{timeout}ms"
        end

        sleep 0.01  # Release GVL for other threads (reduced for better responsiveness)
      end

      response
    end

    def send_data(data)
      raise Error, "Not connected" unless @connected

      stream = open_stream
      unless stream
        puts "❌ Failed to open stream"
        return false
      end

      result = Quicsilver.send_stream(stream, data, true)
      puts "✅ Sent #{data.bytesize} bytes"
      result
    rescue => e
      puts "❌ Send data error: #{e.class} - #{e.message}"
      false
    end
    
    private
    
    def cleanup_failed_connection
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      @connection_data = nil
      @connected = false
    end

    def open_stream
      Quicsilver.open_stream(@connection_data, false)
    end

    def open_unidirectional_stream
      Quicsilver.open_stream(@connection_data, true)
    end

    def send_control_stream
      # Open unidirectional stream
      stream = open_unidirectional_stream

      # Build and send control stream data
      control_data = Quicsilver::HTTP3.build_control_stream
      Quicsilver.send_stream(stream, control_data, false)

      @control_stream = stream
    end
  end
end
