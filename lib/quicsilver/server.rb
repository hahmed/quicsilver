# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running, :connections

    STREAM_EVENT_RECEIVE = "RECEIVE"
    STREAM_EVENT_RECEIVE_FIN = "RECEIVE_FIN"
    STREAM_EVENT_CONNECTION_ESTABLISHED = "CONNECTION_ESTABLISHED"
    STREAM_EVENT_SEND_COMPLETE = "SEND_COMPLETE"
    STREAM_EVENT_CONNECTION_CLOSED = "CONNECTION_CLOSED"

    class << self
      # Registry mapping connection_handle => Server instance
      def server_registry
        @server_registry ||= {}
      end

      # Callback from C extension - delegates to appropriate server instance
      def handle_stream(connection_data, stream_id, event, data)
        connection_handle = connection_data[0]
        server = server_registry[connection_handle]

        if event == STREAM_EVENT_CONNECTION_ESTABLISHED
          # For new connections, use the most recently created server
          # (In a single-server setup, there's only one anyway)
          server = server_registry.values.last
          server&.handle_stream_event(connection_data, stream_id, event, data)
        elsif server
          server.handle_stream_event(connection_data, stream_id, event, data)
        else
          puts "⚠️  Ruby: No server found for connection #{connection_handle}"
        end
      end
    end

    def initialize(port = 4433, address: "0.0.0.0", app: nil, server_configuration: nil)
      @port = port
      @address = address
      @app = app || default_rack_app
      @server_configuration = server_configuration || ServerConfiguration.new
      @running = false
      @listener_data = nil
      @connections = {}

      # Register this server instance so handle_stream callback can find it
      # When first connection arrives, it will be assigned to this server
      self.class.server_registry[object_id] = self
    end

    def handle_stream_event(connection_data, stream_id, event, data)
      connection_handle = connection_data[0]

      case event
      when STREAM_EVENT_CONNECTION_ESTABLISHED
        @connections[connection_handle] = Connection.new(connection_handle, connection_data)

        # Register this connection with this server instance
        self.class.server_registry[connection_handle] = self

        # Send control stream (required)
        stream = Quicsilver.open_stream(connection_data, true)  # unidirectional
        control_data = Quicsilver::HTTP3.build_control_stream
        Quicsilver.send_stream(stream, control_data, false)  # no FIN

        # Open QPACK encoder stream (required)
        encoder_stream = Quicsilver.open_stream(connection_data, true)
        encoder_type = [0x02].pack('C')  # QPACK encoder stream type
        Quicsilver.send_stream(encoder_stream, encoder_type, false)

        # Open QPACK decoder stream (required)
        decoder_stream = Quicsilver.open_stream(connection_data, true)
        decoder_type = [0x03].pack('C')  # QPACK decoder stream type
        Quicsilver.send_stream(decoder_stream, decoder_type, false)
      when STREAM_EVENT_CONNECTION_CLOSED
        cleanup_connection(connection_handle)
      when STREAM_EVENT_SEND_COMPLETE
        puts "🔧 Ruby: Control stream sent to client"
      when STREAM_EVENT_RECEIVE
        connection = @connections[connection_handle]
        return unless connection

        # Get or create stream
        stream = connection.get_stream(stream_id) || QuicStream.new(stream_id)
        connection.add_stream(stream) unless connection.get_stream(stream_id)

        # Accumulate data
        stream.append_data(data)
        puts "🔧 Ruby: Stream #{stream_id}: Buffering #{data.bytesize} bytes (total: #{stream.buffer.bytesize})"
      when STREAM_EVENT_RECEIVE_FIN
        connection = @connections[connection_handle]
        return unless connection

        # Extract stream handle from data (first 8 bytes)
        stream_handle = data[0, 8].unpack1('Q')
        actual_data = data[8..-1] || ""

        # Get or create stream
        stream = connection.get_stream(stream_id) || QuicStream.new(stream_id)
        stream.stream_handle = stream_handle
        stream.append_data(actual_data)

        # Handle bidirectional streams (client requests)
        if stream.bidirectional?
          handle_request(connection, stream)
        else
          # Unidirectional stream (control/QPACK)
          handle_unidirectional_stream(connection, stream)
        end

        # Clean up stream
        connection.remove_stream(stream_id)
      end
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

    def cleanup_connection(connection_handle)
      connection = @connections[connection_handle]
      return unless connection

      # Clean up all streams in the connection
      connection.streams.clear

      # Remove connection from registry
      @connections.delete(connection_handle)
      self.class.server_registry.delete(connection_handle)
    end

    def handle_unidirectional_stream(connection, stream)
      data = stream.buffer
      return if data.empty?

      stream_type = data[0].ord
      payload = data[1..-1]

      case stream_type
      when 0x00 # Control stream
        connection.set_control_stream(stream.stream_id)
        parse_client_control_stream(payload)
      when 0x02 # QPACK encoder stream
        # Store encoder stream for sending dynamic table updates
        connection.set_qpack_encoder_stream(stream.stream_id)
      when 0x03 # QPACK decoder stream
        # Store decoder stream for receiving acknowledgments
        connection.set_qpack_decoder_stream(stream.stream_id)
      else
        raise "⚠️  Ruby: Stream #{stream.stream_id}: Unknown stream type: 0x#{stream_type.to_s(16)}"
      end
    end

    def parse_client_control_stream(data)
      offset = 0
      while offset < data.bytesize
        frame_type, type_len = HTTP3.decode_varint(data.bytes, offset)
        frame_length, length_len = HTTP3.decode_varint(data.bytes, offset + type_len)

        if frame_type == HTTP3::FRAME_SETTINGS
          # Parse client settings
          settings_payload = data[offset + type_len + length_len, frame_length]
          parse_settings_frame(settings_payload)
        end

        offset += type_len + length_len + frame_length
      end
    end

    def parse_settings_frame(payload)
      offset = 0
      settings = {}

      while offset < payload.bytesize
        setting_id, id_len = HTTP3.decode_varint(payload.bytes, offset)
        setting_value, value_len = HTTP3.decode_varint(payload.bytes, offset + id_len)
        settings[setting_id] = setting_value
        offset += id_len + value_len
      end

      settings
    end

    def handle_request(connection, stream)
      parser = HTTP3::RequestParser.new(stream.buffer)
      parser.parse
      env = parser.to_rack_env

      if env && @app
        # Call Rack app
        status, headers, body = @app.call(env)

        # Encode response
        encoder = HTTP3::ResponseEncoder.new(status, headers, body)
        response_data = encoder.encode

        # Send response using stream handle
        if stream.ready_to_send?
          Quicsilver.send_stream(stream.stream_handle, response_data, true)
        else
          raise "❌ Ruby: Stream handle not found for stream #{stream.stream_id}"
        end
      else
        # failed to parse request
        if stream.ready_to_send?
          error_response = encode_error_response(400, "Bad Request")
          Quicsilver.send_stream(stream.stream_handle, error_response, true)
        end
      end
    rescue => e
      puts "❌ Ruby: Error handling request: #{e.class} - #{e.message}"
      puts e.backtrace.first(5)
      error_response = encode_error_response(500, "Internal Server Error")

      Quicsilver.send_stream(stream.stream_handle, error_response, true) if stream.ready_to_send?
    end

    def encode_error_response(status, message)
      body = ["#{status} #{message}"]
      encoder = HTTP3::ResponseEncoder.new(status, {"content-type" => "text/plain"}, body)
      encoder.encode
    end
  end
end
