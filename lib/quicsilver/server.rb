# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running

    STREAM_EVENT_RECEIVE = "RECEIVE"
    STREAM_EVENT_RECEIVE_FIN = "RECEIVE_FIN"
    STREAM_EVENT_CONNECTION_ESTABLISHED = "CONNECTION_ESTABLISHED"
    STREAM_EVENT_SEND_COMPLETE = "SEND_COMPLETE"

    class << self
      def connections
        @connections ||= {}
      end

      def stream_buffers
        @stream_buffers ||= {}
      end

      def stream_handles
        @stream_handles ||= {}
      end

      def rack_app
        @rack_app
      end

      def rack_app=(app)
        @rack_app = app
      end

      def handle_stream(connection_data, stream_id, event, data)
        case event
        when STREAM_EVENT_CONNECTION_ESTABLISHED
          puts "🔧 Ruby: Connection established with client"
          # connection_data is now passed directly from C extension
          # Store it for later use
          connection_handle = connection_data[0]
          connections[connection_handle] = connection_data

          stream = Quicsilver.open_stream(connection_data, true)  # unidirectional
          control_data = Quicsilver::HTTP3.build_control_stream
          Quicsilver.send_stream(stream, control_data, false)  # no FIN
        when STREAM_EVENT_SEND_COMPLETE
          puts "🔧 Ruby: Control stream sent to client"
        when STREAM_EVENT_RECEIVE
          # Accumulate data
          stream_buffers[stream_id] ||= ""
          stream_buffers[stream_id] += data
          puts "🔧 Ruby: Stream #{stream_id}: Buffering #{data.bytesize} bytes (total: #{stream_buffers[stream_id].bytesize})"
        when STREAM_EVENT_RECEIVE_FIN
          # Extract stream handle from data (first 8 bytes)
          stream_handle = data[0, 8].unpack1('Q')
          actual_data = data[8..-1] || ""

          # Store stream handle for later use
          stream_handles[stream_id] = stream_handle

          # Final chunk - process complete message
          stream_buffers[stream_id] ||= ""
          stream_buffers[stream_id] += actual_data
          complete_data = stream_buffers[stream_id]

          # Handle bidirectional streams (client requests)
          if bidirectional?(stream_id)
            handle_http3_request(stream_id, complete_data)
          else
            # Unidirectional stream (control/QPACK)
            puts "✅ Ruby: Stream #{stream_id}: Control/QPACK stream (#{complete_data.bytesize} bytes)"
          end

          # Clean up buffers
          stream_buffers.delete(stream_id)
          stream_handles.delete(stream_id)
        end
      end

      private

      def bidirectional?(stream_id)
        # Client-initiated bidirectional streams have bit 0x02 clear
        (stream_id & 0x02) == 0
      end

      def handle_http3_request(stream_id, data)
        parser = HTTP3::RequestParser.new(data)
        parser.parse
        env = parser.to_rack_env

        if env && rack_app
          puts "✅ Ruby: #{env['REQUEST_METHOD']} #{env['PATH_INFO']}"

          # Call Rack app
          status, headers, body = rack_app.call(env)

          # Encode response
          encoder = HTTP3::ResponseEncoder.new(status, headers, body)
          response_data = encoder.encode

          # Get stream handle from stored handles
          stream_handle = stream_handles[stream_id]
          if stream_handle
            # Send response
            Quicsilver.send_stream(stream_handle, response_data, true)
            puts "✅ Ruby: Response sent: #{status}"
          else
            puts "❌ Ruby: Stream handle not found for stream #{stream_id}"
            # cannot send response, connection is lost
          end
        else
          puts "❌ Ruby: Failed to parse request"
          stream_handle = stream_handles[stream_id]
          if stream_handle
            error_response = encode_error_response(400, "Bad Request")
            Quicsilver.send_stream(stream_handle, error_response, true)
          end
        end
      rescue => e
        puts "❌ Ruby: Error handling request: #{e.class} - #{e.message}"
        puts e.backtrace.first(5)
        error_response = encode_error_response(500, "Internal Server Error")

        stream_handle = stream_handles[stream_id]
        Quicsilver.send_stream(stream_handle, error_response, true) if stream_handle
      end

      def encode_error_response(status, message)
        body = ["#{status} #{message}"]
        encoder = HTTP3::ResponseEncoder.new(status, {"content-type" => "text/plain"}, body)
        encoder.encode
      end
    end

    def initialize(port = 4433, address: "0.0.0.0", app: nil, server_configuration: nil)
      @port = port
      @address = address
      @app = app || default_rack_app
      @server_configuration = server_configuration || ServerConfiguration.new
      @running = false
      @listener_data = nil

      # Set class-level rack app so handle_stream can access it
      self.class.rack_app = @app
    end

    def start
      raise ServerIsRunningError, "Server is already running" if @running

      # Initialize MSQUIC if not already done
      Quicsilver.open_connection

      config = Quicsilver.create_server_configuration(@server_configuration.to_h)
      unless config
        raise ServerConfigurationError, "Failed to create server configuration"
      end

      # Create and start the listener
      @listener_data = start_listener(config)
      start_server(config)

      @running = true

      puts "✅ QUIC server started successfully on #{@address}:#{@port}"
    rescue ServerConfigurationError, ServerListenerError => e
      cleanup_failed_server
      @running = false
      raise e
    rescue => e
      cleanup_failed_server
      @running = false

      error_msg = case e.message
      when /0x16/
        "Invalid parameter error - check certificate files and network configuration"
      when /0x30/
        "Address already in use - port #{@port} may be occupied"
      else
        e.message
      end

      raise ServerError, "Server start failed: #{error_msg}"
    end

    def stop
      return unless @running

      puts "🛑 Stopping QUIC server..."

      if @listener_data
        listener_handle = @listener_data[0]
        Quicsilver.stop_listener(listener_handle)
        Quicsilver.close_listener(@listener_data)
        @listener_data = nil
      end

      @running = false
      puts "👋 Server stopped"    
    rescue
      puts "⚠️  Error during server shutdown"
      # Continue with cleanup even if there are errors
      @listener_data = nil
      @running = false
    end

    def running?
      @running
    end

    def server_info
      {
        address: @address,
        port: @port,
        running: @running,
        cert_file: @cert_file,
        key_file: @key_file
      }
    end

    def wait_for_connections(timeout: nil)
      if timeout
        end_time = Time.now + timeout
        while Time.now < end_time && @running
          Quicsilver.process_events
          sleep(0.01) # Poll every 10ms
        end
      else
        # Keep the server running indefinitely
        # Process events from MSQUIC callbacks
        loop do
          Quicsilver.process_events
          sleep(0.01) # Poll every 10ms
          break unless @running
        end
      end
    end

    private

    def default_rack_app
      ->(env) {
        [200,
         {'Content-Type' => 'text/plain'},
         ["Hello from Quicsilver!\nMethod: #{env['REQUEST_METHOD']}\nPath: #{env['PATH_INFO']}\n"]]
      }
    end

    def start_server(config)
      result = Quicsilver.start_listener(@listener_data.listener_handle, @address, @port)
      unless result
        Quicsilver.close_configuration(config)
        cleanup_failed_server
        raise ServerListenerError, "Failed to start listener on #{@address}:#{@port}"
      end
    end

    def start_listener(config)
      result = Quicsilver.create_listener(config)
      listener_data = ListenerData.new(result[0], result[1])

      unless listener_data
        Quicsilver.close_configuration(config)
        raise ServerListenerError, "Failed to create listener on #{@address}:#{@port}"
      end

      listener_data
    end

    def cleanup_failed_server
      if @listener_data
        begin
          Quicsilver.stop_listener(@listener_data)
          Quicsilver.close_listener(@listener_data)
        rescue
          # Ignore cleanup errors
        ensure
          @listener_data = nil
        end
      end
    end
  end
end
