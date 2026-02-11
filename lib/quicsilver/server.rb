# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running, :connections, :request_registry, :shutting_down

    STREAM_EVENT_RECEIVE = "RECEIVE"
    STREAM_EVENT_RECEIVE_FIN = "RECEIVE_FIN"
    STREAM_EVENT_CONNECTION_ESTABLISHED = "CONNECTION_ESTABLISHED"
    STREAM_EVENT_SEND_COMPLETE = "SEND_COMPLETE"
    STREAM_EVENT_CONNECTION_CLOSED = "CONNECTION_CLOSED"
    STREAM_EVENT_STREAM_RESET = "STREAM_RESET"
    STREAM_EVENT_STOP_SENDING = "STOP_SENDING"

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
      Quicsilver.event_loop.join  # Block until shutdown
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

      Quicsilver.event_loop.stop  # Stop event loop so start unblocks
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

      # Phase 1: Send GOAWAY - tell clients to stop sending new requests
      @connections.each_value { |c| c.send_goaway(HTTP3::MAX_STREAM_ID) }

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

      # Phase 3: Shutdown connections gracefully
      @connections.each_value(&:shutdown)
      sleep 0.1

      # Phase 4: Hard stop
      stop
      @shutting_down = false

      Quicsilver.logger.info("Graceful shutdown complete")
    end

    def handle_stream_event(connection_data, stream_id, event, data) # :nodoc:
      connection_handle = connection_data[0]

      case event
      when STREAM_EVENT_CONNECTION_ESTABLISHED
        connection = Connection.new(connection_handle, connection_data)
        @connections[connection_handle] = connection
        connection.setup_http3_streams

      when STREAM_EVENT_CONNECTION_CLOSED
        @connections.delete(connection_handle)&.streams&.clear

      when STREAM_EVENT_SEND_COMPLETE
        # Buffer cleanup handled in C extension

      when STREAM_EVENT_RECEIVE
        return unless (connection = @connections[connection_handle])
        connection.buffer_data(stream_id, data)

      when STREAM_EVENT_RECEIVE_FIN
        return unless (connection = @connections[connection_handle])

        stream_handle = data[0, 8].unpack1("Q")
        actual_data = data[8..-1] || ""

        # Get buffered data and build stream
        full_data = connection.complete_stream(stream_id, actual_data)
        stream = QuicStream.new(stream_id)
        stream.stream_handle = stream_handle
        stream.append_data(full_data)

        if stream.bidirectional?
          handle_request(connection, stream)
        else
          connection.handle_unidirectional_stream(stream)
        end

      when STREAM_EVENT_STREAM_RESET
        return unless @connections[connection_handle]
        error_code = data.unpack1("Q")
        Quicsilver.logger.debug("Stream #{stream_id} reset by peer with error code: 0x#{error_code.to_s(16)}")
        @request_registry.complete(stream_id)

      when STREAM_EVENT_STOP_SENDING
        return unless @connections[connection_handle]
        error_code = data.unpack1("Q")
        Quicsilver.logger.debug("Stream #{stream_id} stop sending requested with error code: 0x#{error_code.to_s(16)}")
      end
    end

    private

    def default_rack_app
      ->(env) {
        [200,
         {"Content-Type" => "text/plain"},
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

    def handle_request(connection, stream)
      parser = HTTP3::RequestParser.new(stream.data)
      parser.parse
      env = parser.to_rack_env

      if env && @app
        @request_registry.track(
          stream.stream_id,
          connection.handle,
          path: env["PATH_INFO"] || "/",
          method: env["REQUEST_METHOD"] || "GET"
        )

        status, headers, body = @app.call(env)

        raise "Stream handle not found for stream #{stream.stream_id}" unless stream.ready_to_send?

        connection.send_response(stream, status, headers, body)
        @request_registry.complete(stream.stream_id)
      else
        connection.send_error(stream, 400, "Bad Request") if stream.ready_to_send?
      end
    rescue => e
      Quicsilver.logger.error("Error handling request: #{e.class} - #{e.message}")
      Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
      connection.send_error(stream, 500, "Internal Server Error") if stream.ready_to_send?
    ensure
      @request_registry.complete(stream.stream_id) if @request_registry.include?(stream.stream_id)
    end
  end
end
