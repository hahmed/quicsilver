# frozen_string_literal: true

require_relative 'http3/request_encoder'
require_relative 'http3/response_parser'

module Quicsilver
  class Client
    attr_reader :hostname, :port, :unsecure, :connection_timeout

    AlreadyConnectedError = Class.new(StandardError)
    NotConnectedError = Class.new(StandardError)
    StreamFailedToOpenError = Class.new(StandardError)

    FINISHED_EVENTS = %w[RECEIVE_FIN RECEIVE].freeze

    def initialize(hostname, port = 4433, options = {})
      @hostname = hostname
      @port = port
      @unsecure = options.fetch(:unsecure, true)
      @connection_timeout = options.fetch(:connection_timeout, 5000)

      @connection_data = nil
      @connected = false
      @connection_start_time = nil

      @response_buffers = {}  # stream_id => accumulated data
      @pending_requests = {}
      @mutex = Mutex.new
    end
    
    def connect
      raise AlreadyConnectedError if @connected

      Quicsilver.open_connection
      
      # Create configuration
      config = Quicsilver.create_configuration(@unsecure)
      raise ConnectionError, "Failed to create configuration" if config.nil?

      # Create connection (returns [handle, context])
      # Pass self so C extension can route callbacks to this instance
      @connection_data = Quicsilver.create_connection(self)
      raise ConnectionError, "Failed to create connection" if @connection_data.nil?
      
      connection_handle, context_handle = @connection_data
      
      # Start the connection
      success = Quicsilver.start_connection(connection_handle, config, @hostname, @port)
      unless success
        Quicsilver.close_configuration(config)
        cleanup_failed_connection
        raise ConnectionError, "Failed to start connection"
      end

      # Wait for connection to establish or fail
      result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)
      handle_connection_result(result, config)
      
      @connected = true
      @connection_start_time = Time.now

      send_control_stream
      Quicsilver.close_configuration(config) # Clean up config since connection is established

      start_event_loop

      self
    rescue => e
      cleanup_failed_connection
      
      if e.is_a?(ConnectionError) || e.is_a?(TimeoutError)
        raise e
      else
        raise ConnectionError, "Connection failed: #{e.message}"
      end
    end
    
    def disconnect
      return unless @connection_data

      @connected = false
      @event_thread&.join(1)  # Wait max 1 second
      @event_thread = nil

      Quicsilver.close_connection_handle(@connection_data)
      @connection_data = nil
      @connection_start_time = nil

      # Clean up any remaining response buffers
      @mutex.synchronize do
        @response_buffers.clear
        @pending_requests.clear
      end
    rescue
      # TODO: Ignore disconnect errors, maybe log
    ensure
      @connected = false
      @connection_data = nil
      @event_thread = nil
    end

    def get(path, **opts)
      request("GET", path, **opts)
    end

    def post(path, **opts)
      request("POST", path, **opts)
    end

    def patch(path, **opts)
      request("PATCH", path, **opts)
    end

    def delete(path, **opts)
      request("DELETE", path, **opts)
    end

    def head(path, **opts)
      request("HEAD", path, **opts)
    end

    def request(method, path, headers: {}, body: nil, timeout: 5000)
      raise NotConnectedError unless @connected

      response_queue = Queue.new

      request = Quicsilver::HTTP3::RequestEncoder.new(
        method: method,
        path: path,
        scheme: "https",
        authority: authority,
        headers: headers,
        body: body
      )

      stream = open_stream
      raise StreamFailedToOpenError unless stream

      @mutex.synchronize do
        @pending_requests[stream] = response_queue
      end

      # Send data with FIN flag
      result = Quicsilver.send_stream(stream, request.encode, true)

      unless result
        @mutex.synchronize { @pending_requests.delete(stream) }
        raise Error, "Failed to send request"
      end

      Timeout.timeout(timeout / 1000.0) do
        response_queue.pop
      end
    rescue Timeout::Error
      @mutex.synchronize { @pending_requests.delete(stream) }
      raise TimeoutError, "Request timeout after #{timeout}ms"
    end

    def connected?
      @connected && @connection_data && connection_alive?
    end
    
    def connection_info
      info = @connection_data ? Quicsilver.connection_status(@connection_data[1]) : {}
      info.merge(hostname: @hostname, port: @port, uptime: connection_uptime)
    end
    
    def connection_uptime
      return 0 unless @connection_start_time
      Time.now - @connection_start_time
    end

    def authority
      "#{@hostname}:#{@port}"
    end

    # Called directly by C extension via process_events
    # C extension routes to this instance based on client_obj stored in connection context
    # Clients should never call this method directly.
    def handle_stream_event(stream_id, event, data)
      return unless FINISHED_EVENTS.include?(event)

      @mutex.synchronize do
        case event
        when "RECEIVE"
          @response_buffers[stream_id] ||= ""
          @response_buffers[stream_id] += data # Buffer incoming response data
        when "RECEIVE_FIN"
          stream_handle = data[0, 8].unpack1('Q') if data.bytesize >= 8
          actual_data = data[8..-1] || ""

          # Get all buffered data
          full_data = (@response_buffers.delete(stream_id) || "") + actual_data

          # TODO: needed for streaming later
          @stream_handles ||= {}
          @stream_handles[stream_id] = stream_handle if stream_handle

          response_parser = Quicsilver::HTTP3::ResponseParser.new(full_data)
          response_parser.parse

          # Store complete response with body as string
          response = {
            status: response_parser.status,
            headers: response_parser.headers,
            body: response_parser.body.read
          }

          queue = @pending_requests.delete(stream_id)
          queue&.push(response)  # Unblocks request
        end
      end
    rescue => e
      puts "❌ Ruby: Error handling client stream: #{e.class} - #{e.message}"
      puts e.backtrace.first(5)
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

    def start_event_loop
      return if @event_thread&.alive?

      @event_thread = Thread.new do
        while @connected
          Quicsilver.process_events
          sleep 0.001
        end
      end
    end

    def send_control_stream
      # Open unidirectional stream
      stream = open_unidirectional_stream

      # Build and send control stream data
      control_data = Quicsilver::HTTP3.build_control_stream
      Quicsilver.send_stream(stream, control_data, false)

      @control_stream = stream
    end

    def handle_connection_result(result, config)
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
    end

    def connection_alive?
      return false unless (info = Quicsilver.connection_status(@connection_data[1]))
      info["connected"] && !info["failed"]
    rescue
      false
    end
  end
end
