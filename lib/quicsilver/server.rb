# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running, :connections, :request_registry, :shutting_down

    STREAM_EVENT_RECEIVE = "RECEIVE"
    STREAM_EVENT_RECEIVE_FIN = "RECEIVE_FIN"
    STREAM_EVENT_CONNECTION_ESTABLISHED = "CONNECTION_ESTABLISHED"
    STREAM_EVENT_SEND_COMPLETE = "SEND_COMPLETE"
    STREAM_EVENT_CONNECTION_CLOSED = "CONNECTION_CLOSED"

    ServerStopError = Class.new(StandardError)

    class << self
      attr_accessor :instance

      # Callback from C extension - delegates to server instance
      def handle_stream(connection_data, stream_id, event, data)
        instance&.handle_stream_event(connection_data, stream_id, event, data)
      end
    end

    def initialize(port = 4433, address: "0.0.0.0", app: nil, server_configuration: nil)
      @port = port
      @address = address
      @app = app || default_rack_app
      @server_configuration = server_configuration || ServerConfiguration.new
      @running = false
      @shutting_down = false
      @listener_data = nil
      @connections = {}
      @request_registry = RequestRegistry.new

      self.class.instance = self
    end

    def start
      raise ServerIsRunningError, "Server is already running" if @running

      Quicsilver.open_connection
      config = Quicsilver.create_server_configuration(@server_configuration.to_h)
      raise ServerConfigurationError, "Failed to create server configuration" unless config

      # Create and start the listener
      result = Quicsilver.create_listener(config)
      @listener_data = ListenerData.new(result[0], result[1])
      raise ServerListenerError, "Failed to create listener #{@address}:#{@port}"  unless @listener_data

      unless Quicsilver.start_listener(@listener_data.listener_handle, @address, @port)
        Quicsilver.close_configuration(config)
        cleanup_failed_server
        raise ServerListenerError, "Failed to start listener on #{@address}:#{@port}"
      end

      @running = true

      Quicsilver.event_loop.start
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

      if @listener_data && @listener_data.listener_handle
        Quicsilver.stop_listener(@listener_data.listener_handle)
        Quicsilver.close_listener([@listener_data.listener_handle, @listener_data.context_handle])
      end

      @running = false
      @listener_data = nil
    rescue => e
      @listener_data = nil
      @running = false
      raise ServerStopError, "Failed to stop server: #{e.message}"
    end

    def running?
      @running
    end

    # Graceful shutdown: send GOAWAY, wait for in-flight requests, then stop
    def shutdown(timeout: 30)
      return unless @running
      return if @shutting_down

      @shutting_down = true
      Quicsilver.logger.info("Initiating graceful shutdown (timeout: #{timeout}s)")

      # Phase 1: Send GOAWAY with max stream ID to all connections
      # This tells clients to stop sending new requests
      @connections.each_value do |connection|
        send_goaway(connection, HTTP3::MAX_STREAM_ID)
      end

      # Phase 2: Wait for in-flight requests to drain
      deadline = Time.now + timeout
      until @request_registry.empty? || Time.now > deadline
        sleep 0.1
      end

      # Log any requests that didn't complete
      unless @request_registry.empty?
        @request_registry.active_requests.each do |stream_id, req|
          elapsed = Time.now - req[:started_at]
          Quicsilver.logger.warn("Force-closing request: #{req[:method]} #{req[:path]} (stream: #{stream_id}, elapsed: #{elapsed.round(2)}s)")
        end
      end

      # Phase 3: Send final GOAWAY with actual last stream ID and shutdown connections
      @connections.each_value do |connection|
        last_stream_id = connection.streams.keys.select { |id| (id & 0x02) == 0 }.max || 0
        send_goaway(connection, last_stream_id)

        # Graceful QUIC shutdown (sends CONNECTION_CLOSE to peer)
        Quicsilver.connection_shutdown(connection.handle, 0, false)
      end

      # Give connections a moment to close gracefully
      sleep 0.1

      # Phase 4: Hard stop
      stop
      @shutting_down = false

      Quicsilver.logger.info("Graceful shutdown complete")
    end

    def handle_stream_event(connection_data, stream_id, event, data)
      connection_handle = connection_data[0]

      case event
      when STREAM_EVENT_CONNECTION_ESTABLISHED
        connection = Connection.new(connection_handle, connection_data)
        @connections[connection_handle] = connection
        setup_http3_streams(connection)
      when STREAM_EVENT_CONNECTION_CLOSED
        @connections.delete(connection_handle)&.streams&.clear
      when STREAM_EVENT_SEND_COMPLETE
        # TODO...
      when STREAM_EVENT_RECEIVE
        return unless connection = @connections[connection_handle]

        stream = connection.get_stream(stream_id) || QuicStream.new(stream_id)
        connection.add_stream(stream) unless connection.get_stream(stream_id)
        stream.append_data(data)
      when STREAM_EVENT_RECEIVE_FIN
        return unless connection = @connections[connection_handle]

        # Extract stream handle from data (first 8 bytes)
        stream_handle = data[0, 8].unpack1('Q')
        actual_data = data[8..-1] || ""

        stream = connection.get_stream(stream_id) || QuicStream.new(stream_id)
        stream.stream_handle = stream_handle
        stream.append_data(actual_data)

        if stream.bidirectional?
          handle_request(connection, stream)
        else
          handle_unidirectional_stream(connection, stream) # Unidirectional stream (control/QPACK)
        end

        connection.remove_stream(stream_id)
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

    def cleanup_failed_server
      if @listener_data
        begin
          Quicsilver.stop_listener(@listener_data.listener_handle) if @listener_data.listener_handle
          Quicsilver.close_listener([@listener_data.listener_handle, @listener_data.context_handle]) if @listener_data.listener_handle
        rescue
          # Ignore cleanup errors
        ensure
          @listener_data = nil
        end
      end
    end

    def setup_http3_streams(connection)
      connection_data = connection.data

      # Send control stream (required) - store handle for GOAWAY
      control_stream = Quicsilver.open_stream(connection_data, true)
      control_data = HTTP3.build_control_stream
      Quicsilver.send_stream(control_stream, control_data, false)
      connection.server_control_stream = control_stream

      # Open QPACK encoder/decoder streams (required)
      [0x02, 0x03].each do |type|
        stream = Quicsilver.open_stream(connection_data, true)
        Quicsilver.send_stream(stream, [type].pack('C'), false)
      end
    end


    def handle_control_stream(connection, stream)
      return if stream.data.empty?

      case stream.data[0].ord
      when 0x00 then connection.set_control_stream(stream.stream_id)
      when 0x02 then connection.set_qpack_encoder_stream(stream.stream_id)
      when 0x03 then connection.set_qpack_decoder_stream(stream.stream_id)
      end
    end

    def handle_unidirectional_stream(connection, stream)
      data = stream.data
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
      parser = HTTP3::RequestParser.new(stream.data)
      parser.parse
      env = parser.to_rack_env

      if env && @app
        # Track request
        @request_registry.track(
          stream.stream_id,
          connection.handle,
          path: env["PATH_INFO"] || "/",
          method: env["REQUEST_METHOD"] || "GET"
        )

        # Call Rack app
        status, headers, body = @app.call(env)

        # Stream response - send frames as they're ready
        encoder = HTTP3::ResponseEncoder.new(status, headers, body)

        if stream.ready_to_send?
          encoder.stream_encode do |frame_data, fin|
            Quicsilver.send_stream(stream.stream_handle, frame_data, fin) unless frame_data.empty? && !fin
          end
        else
          raise "Stream handle not found for stream #{stream.stream_id}"
        end

        # Mark request complete
        @request_registry.complete(stream.stream_id)
      else
        # failed to parse request
        if stream.ready_to_send?
          error_response = encode_error_response(400, "Bad Request")
          Quicsilver.send_stream(stream.stream_handle, error_response, true)
        end
      end
    rescue => e
      Quicsilver.logger.error("Error handling request: #{e.class} - #{e.message}")
      Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
      error_response = encode_error_response(500, "Internal Server Error")

      Quicsilver.send_stream(stream.stream_handle, error_response, true) if stream.ready_to_send?
    ensure
      # Always complete the request, even on error
      @request_registry.complete(stream.stream_id) if @request_registry.include?(stream.stream_id)
    end

    def encode_error_response(status, message)
      body = ["#{status} #{message}"]
      encoder = HTTP3::ResponseEncoder.new(status, {"content-type" => "text/plain"}, body)
      encoder.encode
    end

    def send_goaway(connection, stream_id)
      return unless connection.server_control_stream

      goaway_frame = HTTP3.build_goaway_frame(stream_id)
      Quicsilver.send_stream(connection.server_control_stream, goaway_frame, false)
    rescue => e
      Quicsilver.logger.error("Failed to send GOAWAY to connection #{connection.handle}: #{e.message}")
    end
  end
end
