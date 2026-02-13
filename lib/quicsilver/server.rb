# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running, :connections, :request_registry, :shutting_down, :max_queue_size, :max_connections

    STREAM_EVENT_RECEIVE = "RECEIVE"
    STREAM_EVENT_RECEIVE_FIN = "RECEIVE_FIN"
    STREAM_EVENT_CONNECTION_ESTABLISHED = "CONNECTION_ESTABLISHED"
    STREAM_EVENT_SEND_COMPLETE = "SEND_COMPLETE"
    STREAM_EVENT_CONNECTION_CLOSED = "CONNECTION_CLOSED"
    STREAM_EVENT_STREAM_RESET = "STREAM_RESET"
    STREAM_EVENT_STOP_SENDING = "STOP_SENDING"

    ServerStopError = Class.new(StandardError)
    DrainTimeoutError = Class.new(StandardError)

    class << self
      attr_accessor :instance

      # Callback from C extension - delegates to server instance
      def handle_stream(connection_data, stream_id, event, data)
        instance&.handle_stream_event(connection_data, stream_id, event, data)
      end
    end

    DEFAULT_THREAD_POOL_SIZE = 5
    DEFAULT_QUEUE_MULTIPLIER = 4
    DEFAULT_MAX_CONNECTIONS = 100

    def initialize(port = 4433, address: "0.0.0.0", app: nil, server_configuration: nil, threads: DEFAULT_THREAD_POOL_SIZE, max_queue_size: nil, max_connections: DEFAULT_MAX_CONNECTIONS)
      @port = port
      @address = address
      @app = app || default_rack_app
      @server_configuration = server_configuration || ServerConfiguration.new
      @running = false
      @shutting_down = false
      @listener_data = nil
      @config_handle = nil
      @connections = {}
      @request_registry = RequestRegistry.new
      @handler_threads = []
      @handler_mutex = Mutex.new
      @thread_pool_size = threads
      @max_queue_size = max_queue_size || threads * DEFAULT_QUEUE_MULTIPLIER
      @work_queue = Queue.new
      @max_connections = max_connections
      @cancelled_streams = Set.new
      @cancelled_mutex = Mutex.new

      self.class.instance = self
    end

    def start
      raise ServerIsRunningError, "Server is already running" if @running

      Quicsilver.open_connection
      @config_handle = Quicsilver.create_server_configuration(@server_configuration.to_h)
      raise ServerConfigurationError, "Failed to create server configuration" unless @config_handle

      result = Quicsilver.create_listener(@config_handle)
      @listener_data = ListenerData.new(result[0], result[1])
      raise ServerListenerError, "Failed to create listener #{@address}:#{@port}"  unless @listener_data

      unless Quicsilver.start_listener(@listener_data.listener_handle, @address, @port, @server_configuration.alpn)
        Quicsilver.close_configuration(@config_handle)
        @config_handle = nil
        cleanup_failed_server
        raise ServerListenerError, "Failed to start listener on #{@address}:#{@port}"
      end

      @running = true

      setup_signal_handlers
      start_worker_pool
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

      drain

      if @listener_data && @listener_data.listener_handle
        Quicsilver.stop_listener(@listener_data.listener_handle)
        Quicsilver.close_listener([@listener_data.listener_handle, @listener_data.context_handle])
      end

      if @config_handle
        Quicsilver.close_configuration(@config_handle)
        @config_handle = nil
      end

      Quicsilver.event_loop.stop
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

    def cancelled_stream?(stream_id)
      @cancelled_mutex.synchronize { @cancelled_streams.include?(stream_id) }
    end

    # Wait for work queue to drain, then shut down the pool
    def drain(timeout: 5)
      Quicsilver.logger.debug("Draining work queue (#{@work_queue.size} pending)")

      deadline = Time.now + timeout

      # Wait for work queue to empty
      while @work_queue.size > 0 && Time.now < deadline
        sleep 0.05
      end

      # Signal workers to exit
      stop_worker_pool
    end

    # Graceful shutdown: send GOAWAY, drain requests, then stop
    def shutdown(timeout: 30)
      return unless @running
      return if @shutting_down

      @shutting_down = true
      Quicsilver.logger.info("Initiating graceful shutdown (timeout: #{timeout}s)")

      # Phase 1: Send GOAWAY - tell clients to stop sending new requests
      @connections.each_value { |c| c.send_goaway(HTTP3::MAX_STREAM_ID) }

      # Phase 2: Drain in-flight requests
      drain(timeout: timeout)

      # Grace period: let pending responses reach clients
      sleep 0.5

      # Log any requests that didn't complete
      unless @request_registry.empty?
        @request_registry.active_requests.each do |stream_id, req|
          elapsed = Time.now - req[:started_at]
          Quicsilver.logger.warn("Force-closing request: #{req[:method]} #{req[:path]} (stream: #{stream_id}, elapsed: #{elapsed.round(2)}s)")
        end
      end

      # Phase 3: Shutdown connections
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
        if @connections.size >= @max_connections
          Quicsilver.logger.warn("Connection limit reached (#{@max_connections}), rejecting connection")
          Quicsilver.connection_shutdown(connection_handle, HTTP3::H3_EXCESSIVE_LOAD, false)
          return
        end

        connection = Connection.new(connection_handle, connection_data)
        @connections[connection_handle] = connection
        connection.setup_http3_streams

      when STREAM_EVENT_CONNECTION_CLOSED
        @connections.delete(connection_handle)&.streams&.clear
        Quicsilver.close_server_connection(connection_handle)

      when STREAM_EVENT_SEND_COMPLETE
        # Buffer cleanup handled in C extension

      when STREAM_EVENT_RECEIVE
        return unless (connection = @connections[connection_handle])
        connection.buffer_data(stream_id, data)

      when STREAM_EVENT_RECEIVE_FIN
        return unless (connection = @connections[connection_handle])

        event = StreamEvent.new(data, "RECEIVE_FIN")

        full_data = connection.complete_stream(stream_id, event.data)
        stream = QuicStream.new(stream_id)
        stream.stream_handle = event.handle
        stream.append_data(full_data)

        if stream.bidirectional?
          connection.track_client_stream(stream_id)
          dispatch_request(connection, stream)
        else
          connection.handle_unidirectional_stream(stream)
        end

      when STREAM_EVENT_STREAM_RESET
        return unless @connections[connection_handle]
        event = StreamEvent.new(data, "STREAM_RESET")
        Quicsilver.logger.debug("Stream #{stream_id} reset by peer with error code: 0x#{event.error_code.to_s(16)}")
        @cancelled_mutex.synchronize { @cancelled_streams.add(stream_id) }
        @request_registry.complete(stream_id)

      when STREAM_EVENT_STOP_SENDING
        return unless @connections[connection_handle]
        event = StreamEvent.new(data, "STOP_SENDING")
        Quicsilver.logger.debug("Stream #{stream_id} stop sending requested with error code: 0x#{event.error_code.to_s(16)}")
        @cancelled_mutex.synchronize { @cancelled_streams.add(stream_id) }
        Quicsilver.stream_reset(event.handle, HTTP3::H3_REQUEST_CANCELLED)
        @request_registry.complete(stream_id)
      end
    end

    private

    def setup_signal_handlers
      %w[INT TERM].each do |signal|
        trap(signal) { Thread.new { shutdown } }
      end
    end

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

    attr_reader :work_queue

    def dispatch_request(connection, stream)
      if @work_queue.size >= @max_queue_size
        Quicsilver.logger.warn("Work queue full (#{@max_queue_size}), rejecting request")
        connection.send_error(stream, 503, "Service Unavailable") if stream.ready_to_send?
      else
        @work_queue.push([connection, stream])
      end
    end

    def start_worker_pool
      @thread_pool_size.times do
        thread = Thread.new do
          while (work = @work_queue.pop)
            break if work == :shutdown
            connection, stream = work
            handle_request(connection, stream)
          end
        end
        @handler_mutex.synchronize { @handler_threads << thread }
      end
    end

    def stop_worker_pool
      @thread_pool_size.times { @work_queue.push(:shutdown) }
      @handler_mutex.synchronize do
        @handler_threads.each { |t| t.join(2) }
        # Raise into any stuck workers
        @handler_threads.each { |t| t.raise(DrainTimeoutError, "drain timeout") if t.alive? }
        @handler_threads.clear
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

        if cancelled_stream?(stream.stream_id)
          Quicsilver.logger.debug("Skipping response for cancelled stream #{stream.stream_id}")
          return
        end

        raise "Stream handle not found for stream #{stream.stream_id}" unless stream.ready_to_send?

        connection.send_response(stream, status, headers, body)
        @request_registry.complete(stream.stream_id)
      else
        connection.send_error(stream, 400, "Bad Request") if stream.ready_to_send?
      end
    rescue DrainTimeoutError
      Quicsilver.logger.debug("Request interrupted by drain: stream #{stream.stream_id}")
    rescue => e
      Quicsilver.logger.error("Error handling request: #{e.class} - #{e.message}")
      Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
      connection.send_error(stream, 500, "Internal Server Error") if stream.ready_to_send?
    ensure
      @request_registry.complete(stream.stream_id) if @request_registry.include?(stream.stream_id)
      @cancelled_mutex.synchronize { @cancelled_streams.delete(stream.stream_id) }
    end
  end
end
