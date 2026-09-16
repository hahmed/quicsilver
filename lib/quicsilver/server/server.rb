# frozen_string_literal: true

require_relative "scheduler"
require_relative "schedulers/thread_scheduler"
require_relative "web_transport_registry"
require_relative "web_transport_session"
require_relative "web_transport_stream"

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running, :connections, :request_registry, :shutting_down, :max_queue_size, :max_connections, :scheduler

    DEFAULT_THREAD_POOL_SIZE = 5
    DEFAULT_QUEUE_MULTIPLIER = 4
    DEFAULT_MAX_CONNECTIONS = 100
    STREAM_EVENT_RECEIVE = "RECEIVE"
    STREAM_EVENT_RECEIVE_FIN = "RECEIVE_FIN"
    STREAM_EVENT_CONNECTION_ESTABLISHED = "CONNECTION_ESTABLISHED"
    STREAM_EVENT_SEND_COMPLETE = "SEND_COMPLETE"
    STREAM_EVENT_CONNECTION_CLOSED = "CONNECTION_CLOSED"
    STREAM_EVENT_STREAM_RESET = "STREAM_RESET"
    STREAM_EVENT_STOP_SENDING = "STOP_SENDING"
    STREAM_EVENT_START_COMPLETE = "STREAM_START_COMPLETE"
    STREAM_EVENT_PEER_ACCEPTED = "STREAM_PEER_ACCEPTED"
    STREAM_EVENT_SHUTDOWN_COMPLETE = "STREAM_SHUTDOWN_COMPLETE"

    ServerStopError = Class.new(Quicsilver::Error)
    DrainTimeoutError = Class.new(Quicsilver::Error)

    # Tracks an in-flight streaming request between RECEIVE and RECEIVE_FIN.
    # The stream handle arrives at RECEIVE_FIN; the worker thread waits for it.
    PendingStream = Struct.new(:connection, :body, :request, :stream_id, :stream_handle, :handle_ready, :frame_buffer, :priority, keyword_init: true) do
      def initialize(**)
        super
        self.handle_ready = Queue.new
        self.frame_buffer = "".b
      end

      # Called by RECEIVE_FIN handler to provide the stream handle
      def complete(handle)
        self.stream_handle = handle
        handle_ready.push(true)
      end

      # Called by worker thread to wait for the stream handle
      def wait_for_handle(timeout: 30)
        handle_ready.pop(timeout: timeout)
        stream_handle
      end
    end

    class << self
      attr_accessor :instance

      # Callback from C extension - delegates to server instance
      def handle_stream(connection_data, stream_id, event, data, early_data)
        instance&.handle_stream_event(connection_data, stream_id, event, data, early_data)
      end
    end

    # Default bind address is 0.0.0.0 (IPv4).
    #
    # ⚠️  IPv4 vs IPv6 matters for QUIC!
    # MsQuic creates either an AF_INET or AF_INET6 socket based on the address.
    # On macOS, MsQuic sets IPV6_V6ONLY=1 by default (no dual-stack), so:
    #   - address: "::"      → IPv6 only (drops IPv4 UDP packets silently)
    #   - address: "0.0.0.0" → IPv4 only (most /etc/hosts map to 127.0.0.1)
    #
    # For HTTP/3 Alt-Svc upgrades to work, the browser must be able to reach
    # the QUIC server at the same IP family it used for the TCP connection.
    # Since most local setups map hostnames to 127.0.0.1 in /etc/hosts,
    # defaulting to 0.0.0.0 (IPv4) is the safest choice.
    #
    # If you need IPv6, either:
    #   1. Add "::1 your-hostname" to /etc/hosts, OR
    #   2. Run two server instances (one IPv4, one IPv6) like Caddy/ngtcp2
    def initialize(port = 4433, address: "0.0.0.0", app: nil, server_configuration: nil, threads: DEFAULT_THREAD_POOL_SIZE, max_queue_size: nil, max_connections: DEFAULT_MAX_CONNECTIONS, scheduler: nil)
      @port = port
      @address = address
      @app = app || default_rack_app
      @server_configuration = server_configuration || Transport::Configuration.new
      @running = false
      @shutting_down = false
      @listener_data = nil
      @config_handle = nil
      @connections = {}
      @request_registry = RequestRegistry.new
      @thread_pool_size = threads
      @max_queue_size = max_queue_size || threads * DEFAULT_QUEUE_MULTIPLIER
      @scheduler = build_scheduler(scheduler)
      @max_connections = max_connections
      @cancelled_streams = Set.new
      @cancelled_mutex = Mutex.new
      @pending_streams = {}
      @pending_mutex = Mutex.new
      @datagram_callback = nil
      @connection_callback = nil
      @connection_closed_callback = nil
      @connection_migrated_callback = nil
      @connection_error_callback = nil
      @webtransport = WebTransportRegistry.new

      protocol_app = wrap_app(@app, @server_configuration.mode)

      @request_handler = RequestHandler.new(
        app: protocol_app,
        configuration: @server_configuration,
        request_registry: @request_registry,
        cancelled_streams: @cancelled_streams,
        cancelled_mutex: @cancelled_mutex
      )

      self.class.instance = self
    end

    # Send an unreliable datagram to a connection (RFC 9297 / QUIC RFC 9221).
    # Must fit in a single QUIC packet (~1200 bytes).
    # Requires peer to have advertised SETTINGS_H3_DATAGRAM=1.
    #
    #   server.datagram_send(connection, "real-time-update")
    #
    def datagram_send(connection, data)
      unless connection.settings[Protocol::SETTINGS_H3_DATAGRAM]
        raise Error, "Peer did not advertise SETTINGS_H3_DATAGRAM support"
      end
      Quicsilver.datagram_send(connection.data, data.to_s.b)
    end

    # Register a callback for received datagrams.
    #
    #   server.on_datagram { |connection, data| puts "Got: #{data}" }
    #
    def on_datagram(&block)
      @datagram_callback = block
    end

    # Register a callback for new QUIC connections.
    #
    #   server.on_connection { |conn|
    #     puts "New connection from #{conn.remote_address} (resumed: #{conn.session_resumed})"
    #   }
    #
    def on_connection(&block)
      @connection_callback = block
    end

    # Register a callback for closed connections.
    #
    #   server.on_connection_closed { |conn| StatsD.decrement("quic.connections") }
    #
    def on_connection_closed(&block)
      @connection_closed_callback = block
    end

    # Register a callback for connection migration (client IP changed).
    # This event only exists in QUIC — TCP connections die on IP change.
    #
    #   server.on_connection_migrated { |conn, old_address, new_address|
    #     Rails.logger.info("Client migrated #{old_address} → #{new_address}")
    #   }
    #
    def on_connection_migrated(&block)
      @connection_migrated_callback = block
    end

    # Register a callback for connection errors (transport failure or peer shutdown).
    #
    #   server.on_connection_error { |conn, error_code, reason|
    #     # reason: :transport — network/protocol failure
    #     # reason: :peer     — client sent CONNECTION_CLOSE
    #     # error_code: QUIC/HTTP/3 error code (e.g. H3_NO_ERROR = 0x100)
    #     Envoy.drain(conn) if reason == :transport
    #   }
    #
    def on_connection_error(&block)
      @connection_error_callback = block
    end

    def start
      raise ServerIsRunningError, "Server is already running" if @running

      configure_transport_server_id
      Quicsilver.open_connection
      @config_handle = Quicsilver.create_server_configuration(@server_configuration.to_h)
      raise ServerConfigurationError, "Failed to create server configuration" unless @config_handle

      create_listener
      configure_listener
      start_listener

      @running = true

      setup_signal_handlers
      @scheduler.start
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

    def draining?
      @shutting_down
    end

    def ready?
      @running && !draining? && !@scheduler.full?
    end

    # Return a point-in-time snapshot of app-server and transport state.
    #
    # The top-level server values are Quicsilver-owned facts: listener state,
    # Ruby connection/request counts, and scheduler queue pressure. The
    # "transport" entry exposes process-wide QUIC transport counters, so it may
    # include activity from other Quicsilver servers/clients in the same process.
    def stats
      {
        "cibir" => configured_cibir,
        "running" => @running,
        "ready" => ready?,
        "draining" => draining?,
        "shutting_down" => @shutting_down,
        "connections" => {
          "active" => @connections.size,
          "max" => @max_connections
        },
        "requests" => {
          "active" => @request_registry.active_count
        },
        "scheduler" => {
          "threads" => @thread_pool_size,
          "pending" => @scheduler.pending,
          "max_queue_size" => @max_queue_size,
          "full" => @scheduler.full?
        },
        "transport" => transport_counters
      }
    end

    def connection_snapshots
      @connections.values.map(&:to_h)
    end

    def cancelled_stream?(stream_id, connection_handle)
      @cancelled_mutex.synchronize { @cancelled_streams.include?([connection_handle, stream_id]) }
    end

    # Wait for work queue to drain, then shut down the scheduler
    def drain(timeout: 5)
      Quicsilver.logger.debug("Draining work queue (#{@scheduler.pending} pending)")
      @scheduler.drain(timeout: timeout)
      @scheduler.stop
    end

    # Graceful shutdown: send GOAWAY, drain requests, then stop
    def shutdown(timeout: 30)
      return unless @running
      return if @shutting_down

      @shutting_down = true
      Quicsilver.logger.info("Initiating graceful shutdown (timeout: #{timeout}s)")

      # Phase 1: Send GOAWAY - tell clients to stop sending new requests
      @connections.each_value { |c| c.send_goaway(Protocol::MAX_STREAM_ID) }

      # Phase 2: Drain in-flight requests
      drain(timeout: timeout)

      # Phase 2b: Send final GOAWAY with actual last processed stream ID (RFC 9114 §5.2)
      @connections.each_value do |c|
        c.send_goaway
      rescue => e
        Quicsilver.logger.debug("Second GOAWAY failed: #{e.message}")
      end

      # Grace period: let pending responses reach clients
      sleep [0.5, timeout * 0.1].min

      # Log any requests that didn't complete
      unless @request_registry.empty?
        @request_registry.active_requests.each do |request_id, req|
          stream_id = req[:stream_id] || request_id
          elapsed = Time.now - req[:started_at]
          Quicsilver.logger.warn("Force-closing request: #{req[:method]} #{req[:path]} (stream: #{stream_id}, elapsed: #{elapsed.round(2)}s)")
        end
      end

      # Phase 3: Shutdown connections
      @connections.each_value(&:shutdown)
      sleep [0.1, timeout * 0.05].min

      # Phase 4: Hard stop
      stop
      @shutting_down = false

      Quicsilver.logger.info("Graceful shutdown complete")
    end

    def handle_stream_event(connection_data, stream_id, event, data, early_data) # :nodoc:
      connection_handle = connection_data[0]

      case event
      when STREAM_EVENT_CONNECTION_ESTABLISHED
        if @connections.size >= @max_connections
          Quicsilver.logger.warn("Connection limit reached (#{@max_connections}), rejecting connection")
          Quicsilver.connection_shutdown(connection_handle, Protocol::H3_EXCESSIVE_LOAD, false)
          return
        end

        quic_connection_ids = Quicsilver.connection_ids(connection_handle)
        connection_id = quic_connection_ids["original_destination_connection_id"]
        connection = Transport::Connection.new(
          connection_handle,
          connection_data,
          max_header_size: @server_configuration.max_header_size,
          connection_id: connection_id,
          transport_server_id: @server_configuration.transport_server_id
        )
        connection.resolve_remote_address!
        @connections[connection_handle] = connection
        connection.setup_http3_streams
        @connection_callback&.call(connection)
      when STREAM_EVENT_CONNECTION_CLOSED
        handle_connection_closed(connection_handle)
      when STREAM_EVENT_SEND_COMPLETE
        # Buffer cleanup handled in C extension
      when STREAM_EVENT_SHUTDOWN_COMPLETE
        return unless (connection = @connections[connection_handle])
        handle_stream_shutdown(connection, stream_id, Transport::StreamEvent.new(data, event).handle)
      when STREAM_EVENT_RECEIVE
        return unless (connection = @connections[connection_handle])
        handle_receive(connection, connection_handle, stream_id, data, early_data: early_data)
      when STREAM_EVENT_RECEIVE_FIN
        return unless (connection = @connections[connection_handle])
        handle_receive_fin(connection, connection_handle, stream_id, data, early_data: early_data)
      when STREAM_EVENT_STREAM_RESET
        return unless (connection = @connections[connection_handle])
        event = Transport::StreamEvent.new(data, "STREAM_RESET")
        Quicsilver.logger.debug("Stream #{stream_id} reset by peer with error code: 0x#{event.error_code.to_s(16)}")

        # Closing a critical unidirectional stream is a connection error (RFC 9114 §6.2.1)
        if connection.critical_stream?(stream_id)
          Quicsilver.logger.error("Critical stream #{stream_id} reset by peer")
          Quicsilver.connection_shutdown(connection_handle, Protocol::H3_CLOSED_CRITICAL_STREAM, false) rescue nil
        elsif (wt = @webtransport.for(connection_handle).unregister(stream_id))
          wt.notify_close
          connection.remove_stream(stream_id)
        elsif (wt_session = @webtransport.for(connection_handle).session_for_stream(stream_id))
          wt_session.remove_stream(stream_id, error_code: event.error_code)
        elsif !@webtransport.for(connection_handle).known_stream?(stream_id)
          cancel_stream(connection, stream_id)
        end
      when STREAM_EVENT_STOP_SENDING
        return unless (connection = @connections[connection_handle])
        event = Transport::StreamEvent.new(data, "STOP_SENDING")
        Quicsilver.logger.debug("Stream #{stream_id} stop sending requested with error code: 0x#{event.error_code.to_s(16)}")
        return if @webtransport.for(connection_handle).cancel_pending_connect(stream_id, event.handle)

        # §4.4: STOP_SENDING on a WebTransport stream is delivered to the
        # application, like RESET_STREAM. Without this it falls through to the
        # HTTP/3 cancel below, which answers with the wrong code and runs
        # request bookkeeping for a stream that is not a request.
        if (wt_session = @webtransport.for(connection_handle).session_for_stream(stream_id))
          wt_session.remove_stream(stream_id, error_code: event.error_code)
        elsif !@webtransport.for(connection_handle).known_stream?(stream_id)
          Quicsilver.stream_reset(event.handle, Protocol::H3_REQUEST_CANCELLED)
          cancel_stream(connection, stream_id)
        end
      when STREAM_EVENT_START_COMPLETE
        return unless @connections.key?(connection_handle)
        @webtransport.for(connection_handle).stream_started(stream_id, Transport::StreamEvent.new(data, event).handle)
        # peer_accepted=true: stream is flowing. false: queued at peer's limit.
        # Server-side: this fires for outbound streams (control, QPACK).
        # Frequent false here means the client's stream limit is too low.
        accepted = data.getbyte(8) == 1
        Quicsilver.logger.debug("Stream #{stream_id} start complete (peer_accepted=#{accepted})")
      when STREAM_EVENT_PEER_ACCEPTED
        # Queued stream now accepted — client sent MAX_STREAMS.
        Quicsilver.logger.debug("Stream #{stream_id} accepted by peer (MAX_STREAMS raised)")
      when "CONNECTION_ERROR"
        return unless (connection = @connections[connection_handle])
        if @connection_error_callback && data.bytesize >= 13
          error_code = data.unpack1("Q<")
          reason = data.getbyte(12) == 0 ? :transport : :peer
          @connection_error_callback.call(connection, error_code, reason)
        end
      when "CONNECTION_MIGRATED"
        return unless (connection = @connections[connection_handle])
        old_address = connection.remote_address
        new_address = data.force_encoding(Encoding::UTF_8)
        connection.instance_variable_set(:@remote_address, new_address)
        @connection_migrated_callback&.call(connection, old_address, new_address)
      when "DATAGRAM_RECEIVED"
        return unless (connection = @connections[connection_handle])
        unless @webtransport.for(connection_handle).receive_datagram(data)
          @datagram_callback&.call(connection, data)
        end
      end
    end

    private

    def configure_transport_server_id
      return unless @server_configuration.transport_server_id

      Quicsilver.apply_msquic_server_id([@server_configuration.transport_server_id].pack("H*"))
    rescue RuntimeError => e
      raise TransportError.new(e.message, status: TransportError.parse_status(e.message))
    end

    def create_listener
      result = Quicsilver.create_listener(@config_handle)
      @listener_data = ListenerData.new(result[0], result[1])
      raise ServerListenerError, "Failed to create listener #{@address}:#{@port}" unless @listener_data
    end

    # Configure listener-level CIBIR routing bytes before starting the listener.
    def configure_listener
      if @server_configuration.cibir_id
        Quicsilver.configure_listener_cibir(
          @listener_data.listener_handle,
          @server_configuration.cibir_bytes
        )
      end
    end

    def handle_stream_shutdown(connection, stream_id, handle)
      return unless @webtransport.for(connection.handle).stream_shutdown_complete(stream_id, handle: handle)

      connection.remove_stream(stream_id)
    rescue StandardError
      connection.remove_stream(stream_id)
      raise
    end

    def handle_connection_closed(connection_handle)
      connection = @connections.delete(connection_handle)
      begin
        close_webtransport_sessions(connection_handle)
        @connection_closed_callback&.call(connection) if connection
      ensure
        connection&.streams&.clear
        Quicsilver.close_server_connection(connection_handle)
      end
    end

    def close_webtransport_sessions(connection_handle)
      @webtransport.drop(connection_handle).each do |session|
        session.notify_close
      rescue StandardError => error
        Quicsilver.logger.error("WebTransport session #{session.stream_id} close failed: #{error.class}: #{error.message}")
      end
    end

    def start_listener
      return if Quicsilver.start_listener(@listener_data.listener_handle, @address, @port, @server_configuration.alpn)

      Quicsilver.close_configuration(@config_handle)
      @config_handle = nil
      cleanup_failed_server
      raise ServerListenerError, "Failed to start listener on #{@address}:#{@port}"
    end

    def configured_cibir
      if @server_configuration.cibir_id
        {
          "id" => @server_configuration.cibir_id,
          "offset" => 0
        }
      end
    end

    def transport_counters
      Quicsilver.transport_counters
    rescue RuntimeError => error
      raise unless error.message.include?("QUIC transport not initialized")

      nil
    end

    def cancel_stream(connection, stream_id)
      @cancelled_mutex.synchronize { @cancelled_streams.add([connection.handle, stream_id]) }
      pending = @pending_mutex.synchronize { @pending_streams.delete([connection.handle, stream_id]) }
      pending&.body&.close(RuntimeError.new("Stream #{stream_id} cancelled"))
      @request_registry.complete(stream_id, connection.handle)
      connection.remove_stream(stream_id)
    end

    # Wrap the user's app for the configured mode.
    # Rack mode: inject rack.early_hints support, then wrap with protocol-rack.
    # Falcon mode: pass through as-is (native protocol-http app).
    def wrap_app(app, mode)
      case mode
      when :falcon then app
      else Server::RackAdapter.new(app)
      end
    end

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

    # RECEIVE data is always [stream_handle(8)][payload...] from C.
    HANDLE_SIZE = 8

    def handle_receive(connection, connection_handle, stream_id, data, early_data: false)
      stream_handle = data.byteslice(0, HANDLE_SIZE)&.unpack1("Q<")
      payload = data.byteslice(HANDLE_SIZE..-1) || "".b
      return if @webtransport.for(connection_handle).route_owned_stream(stream_id, stream_handle, payload)

      # Unidirectional streams (control, QPACK) must be processed incrementally —
      # they never send FIN, so waiting for RECEIVE_FIN would mean never parsing.
      if Transport::StreamId.unidirectional?(stream_id)
        begin
          stream_type, stream_payload = connection.receive_unidirectional_data(stream_id, payload)
          if stream_type == :webtransport_uni
            route_wt_uni_stream(connection_handle, stream_id, stream_handle, stream_payload)
          end
          if connection.settings_received? && (request = @webtransport.for(connection_handle).take_pending_connect)
            establish_webtransport(connection, request)
          end
        rescue Protocol::FrameError => e
          Quicsilver.logger.error("Control stream error: #{e.message} (0x#{e.error_code.to_s(16)})")
          Quicsilver.connection_shutdown(connection_handle, e.error_code, false) rescue nil
        end
      else
        handle_bidi_receive(connection, connection_handle, stream_id, stream_handle, payload, early_data: early_data)
      end
    end

    def handle_bidi_receive(connection, connection_handle, stream_id, stream_handle, payload, early_data: false)
      manager = @webtransport.for(connection_handle)

      pending = @pending_mutex.synchronize { @pending_streams[[connection_handle, stream_id]] }
      if pending
        pending.frame_buffer << payload
        drain_data_frames(pending)
      elsif (wt_payload = manager.pending_payload(stream_id, stream_handle, payload))
        accept_webtransport_stream(connection_handle, stream_id, stream_handle, wt_payload)
      elsif manager.pending_stream?(stream_id)
      elsif contains_headers_frame?(payload)
        dispatch_streaming(connection, connection_handle, stream_id, payload, stream_handle: stream_handle, early_data: early_data)
      else
        connection.buffer_data(stream_id, payload)
      end
    end

    def handle_receive_fin(connection, connection_handle, stream_id, data, early_data: false)
      event = Transport::StreamEvent.new(data, "RECEIVE_FIN")
      manager = @webtransport.for(connection_handle)
      return if manager.route_owned_stream(stream_id, event.handle, event.data, fin: true)

      if connection.uni_stream_type(stream_id) == :webtransport_uni
        stream = manager.route_unidirectional_stream(stream_id, event.handle, event.data, fin: true)
        stream&.notify_read_close
        return
      end

      pending = @pending_mutex.synchronize { @pending_streams[[connection_handle, stream_id]] }
      if pending
        complete_streaming_request(pending, event)
      elsif Transport::StreamId.bidirectional?(stream_id) &&
          (wt_payload = manager.pending_payload(stream_id, event.handle, event.data))
        accept_webtransport_stream(connection_handle, stream_id, event.handle, wt_payload)
        manager.active_stream(stream_id)&.notify_read_close
      elsif manager.pending_stream?(stream_id)
        manager.reject_stream(stream_id, event.handle)
      else
        complete_buffered_request(connection, connection_handle, stream_id, event, early_data: early_data)
      end
    end

    def complete_streaming_request(pending, event)
      if event.data && !event.data.empty?
        pending.frame_buffer << event.data
        drain_data_frames(pending)
      end
      pending.body.close_write
      pending.complete(event.handle)
    end

    def complete_buffered_request(connection, connection_handle, stream_id, event, early_data: false)
      full_data = connection.complete_stream(stream_id, event.data)
      stream = Transport::InboundStream.new(stream_id)
      stream.stream_handle = event.handle
      stream.append_data(full_data)

      if stream.bidirectional?
        connection.track_client_stream(stream_id)
        dispatch_streaming(connection, connection_handle, stream_id, full_data,
          stream_handle: event.handle, early_data: early_data, completed_stream: stream)
      else
        begin
          stream_type, payload = connection.handle_unidirectional_stream(stream)
          if stream_type == :webtransport_uni
            wt_stream = route_wt_uni_stream(connection_handle, stream_id, stream.stream_handle, payload, fin: true)
            wt_stream&.notify_read_close
          end
        rescue Protocol::FrameError => e
          Quicsilver.logger.error("Control stream error: #{e.message} (0x#{e.error_code.to_s(16)})")
          Quicsilver.connection_shutdown(connection_handle, e.error_code, false) rescue nil
        end
      end
    end

    def dispatch_request(connection, stream, early_data: false)
      if @scheduler.full?
        Quicsilver.logger.warn("Work queue full (#{@max_queue_size}), rejecting request")
        connection.send_error(stream, 503, "Service Unavailable") if stream.writable?
      else
        @scheduler.enqueue([connection, stream, early_data])
      end
    end

    # Send an error response on a stream we only hold a raw handle for.
    # Without a handle the peer has not given us anywhere to write yet, so the
    # stream is left for the normal reset/close path.
    def send_stream_error(connection, stream_id, stream_handle, status, message)
      return unless stream_handle

      stream = Transport::InboundStream.new(stream_id)
      stream.stream_handle = stream_handle
      connection.send_error(stream, status, message) if stream.writable?
    end

    def build_scheduler(scheduler_class)
      klass = scheduler_class || Schedulers::ThreadScheduler

      klass.new(
        concurrency: @thread_pool_size,
        max_queue_size: @max_queue_size
      ) do |work|
        if work.is_a?(Array) && work[0] == :streaming
          handle_streaming_request(work[1])
        else
          connection, stream, early_data = work
          @request_handler.call(connection, stream, early_data: early_data)
        end
      end
    end

    # Admit requests when headers arrive, whether or not FIN accompanies them.
    # Completed HTTP requests keep their normal worker dispatch.
    def dispatch_streaming(connection, connection_handle, stream_id, data, stream_handle: nil, early_data: false, completed_stream: nil)
      parser = Protocol::RequestParser.new(
        data,
        max_header_size: @server_configuration.max_header_size,
        max_header_count: @server_configuration.max_header_count,
        max_frame_payload_size: @server_configuration.max_frame_payload_size
      )
      parser.parse
      parser.validate_headers!

      headers = parser.headers
      if headers.empty?
        dispatch_request(connection, completed_stream, early_data: early_data) if completed_stream
        return
      end

      # RFC 9114 §5.2: Reject requests on streams at or above the GOAWAY stream ID
      if connection.local_goaway_id && stream_id >= connection.local_goaway_id
        Quicsilver.logger.debug("Rejecting stream #{stream_id} after GOAWAY (#{connection.local_goaway_id})")
        return
      end

      method = headers[":method"]

      Quicsilver.logger.debug(
        "HTTP/3 request stream=#{stream_id} method=#{method.inspect} " \
        "path=#{headers[":path"].inspect} protocol=#{headers[":protocol"].inspect} " \
        "authority=#{headers[":authority"].inspect} headers=#{headers.inspect}"
      )

      if method == "CONNECT" && Protocol::WebTransport.protocol?(headers[":protocol"])
        dispatch_webtransport_connect(connection, stream_id, headers, data,
          stream_handle: stream_handle, early_data: early_data, fin: !completed_stream.nil?)
      elsif completed_stream
        dispatch_request(connection, completed_stream, early_data: early_data)
      else
        enqueue_streaming_request(connection, stream_id, parser, data,
          stream_handle: stream_handle, early_data: early_data)
      end
    rescue Protocol::FrameError => e
      Quicsilver.logger.error("Frame error: #{e.message}")
      Quicsilver.connection_shutdown(connection_handle, e.error_code, false) rescue nil
    rescue Protocol::MessageError => e
      if completed_stream
        dispatch_request(connection, completed_stream, early_data: early_data)
      else
        Quicsilver.logger.error("Message error on stream #{stream_id}: #{e.message}")
      end
    rescue => e
      Quicsilver.logger.error("Error in streaming dispatch: #{e.class} - #{e.message}")
    end

    def dispatch_webtransport_connect(connection, stream_id, headers, data, stream_handle:, early_data:, fin: false)
      # Validated HEADERS exist. Preserve following bytes, including partial
      # frames, for the session's incremental CONNECT decoder.
      header_end = Protocol::FrameReader.each(data) do |type, _payload, offset|
        break offset if type == Protocol::FRAME_HEADERS
      end
      request = WebTransportManager::ConnectRequest.new(
        stream_id: stream_id, stream_handle: stream_handle, headers: headers,
        data: data.byteslice(header_end..), early_data: early_data, fin: fin
      )
      if connection.settings_received?
        establish_webtransport(connection, request)
      else
        @webtransport.for(connection.handle).defer_connect(request)
      end
    end

    def establish_webtransport(connection, request)
      unless connection.webtransport_settings_valid?(request.headers[":protocol"])
        @webtransport.for(connection.handle).reject_stream(
          request.stream_id, request.stream_handle, error_code: Protocol::H3_MESSAGE_ERROR
        )
        return
      end

      session = accept_webtransport(connection, connection.handle, request.stream_id,
        request.stream_handle, request.headers, early_data: request.early_data)
      session&.receive_connect_stream_data(request.data, fin: request.fin)
    end

    def enqueue_streaming_request(connection, stream_id, parser, data, stream_handle:, early_data:)
      connection_handle = connection.handle
      headers = parser.headers
      method = headers[":method"]

      if @server_configuration.early_data_policy == :reject &&
         early_data && !RequestHandler::SAFE_METHODS.include?(method)
        Quicsilver.logger.debug("Rejected 0-RTT #{method} on stream #{stream_id} (no stream handle to send 425)")
        return
      end

      # Reject before tracking the request so overload cannot leave orphaned state.
      if @scheduler.full?
        Quicsilver.logger.warn("Work queue full (#{@max_queue_size}), shedding stream #{stream_id}")
        send_stream_error(connection, stream_id, stream_handle, 503, "Service Unavailable")
        return
      end

      request, body = @request_handler.adapter.build_request(
        headers,
        remote_address: connection.remote_address,
        remote_port: connection.remote_port,
        transport_context: connection.request_context(stream_id: stream_id)
      )
      request.headers.add("quicsilver-early-data", early_data.to_s)

      # Copy complete DATA payloads; partial frames stay in the pending buffer.
      if body && parser.body.size > 0
        body.write(parser.body.read)
      end

      pending = PendingStream.new(
        connection: connection,
        body: body,
        request: request,
        stream_id: stream_id,
        priority: parser.priority
      )

      # Unconsumed bytes go into the frame buffer for incremental parsing
      remainder = data.byteslice(parser.bytes_consumed..-1)
      if remainder && remainder.bytesize > 0
        pending.frame_buffer << remainder
        drain_data_frames(pending)
      end
      @pending_mutex.synchronize { @pending_streams[[connection_handle, stream_id]] = pending }

      connection.track_client_stream(stream_id)
      @request_registry.track(stream_id, connection_handle,
        path: headers[":path"] || "/", method: method || "GET")

      @scheduler.enqueue([:streaming, pending])
    end

    def handle_streaming_request(pending)
      response = @request_handler.adapter.call(pending.request)

      # Wait for RECEIVE_FIN to provide the stream handle
      stream_handle = pending.wait_for_handle(timeout: 30)
      unless stream_handle
        Quicsilver.logger.error("Timed out waiting for stream handle on stream #{pending.stream_id}")
        return
      end

      return if cancelled_stream?(pending.stream_id, pending.connection.handle)

      headers = response.headers

      trailers = if headers.respond_to?(:trailer?) && headers.trailer?
        trailer_hash = {}
        headers.trailer.each { |name, value| trailer_hash[name] = value }
        trailer_hash
      end

      response_headers = {}
      if headers.respond_to?(:header)
        headers.header.each { |name, value| response_headers[name] = value }
      else
        headers&.each { |name, value| response_headers[name] = value }
      end

      if !response_headers.key?("content-length") && response.body&.length
        response_headers["content-length"] = response.body.length.to_s
      end

      stream = Transport::InboundStream.new(pending.stream_id)
      stream.stream_handle = stream_handle

      pending.connection.apply_stream_priority(stream, pending.priority)
      pending.connection.send_response(stream, response.status, response_headers, response.body,
        head_request: pending.request.method == "HEAD", trailers: trailers)
      @request_registry.complete(pending.stream_id, pending.connection.handle)
    rescue => e
      Quicsilver.logger.error("Streaming request error: #{e.class} - #{e.message}")
      if pending.stream_handle
        stream = Transport::InboundStream.new(pending.stream_id)
        stream.stream_handle = pending.stream_handle
        pending.connection.send_error(stream, 500, "Internal Server Error") if stream.writable?
      end
    ensure
      @pending_mutex.synchronize { @pending_streams.delete([pending.connection.handle, pending.stream_id]) }
      @cancelled_mutex.synchronize { @cancelled_streams.delete([pending.connection.handle, pending.stream_id]) }
      @request_registry.complete(pending.stream_id, pending.connection.handle)
      pending.connection.remove_stream(pending.stream_id)
    end

    # Incrementally extract complete DATA frame payloads from the frame buffer.
    # Handles MsQuic splitting frames across RECEIVE callbacks — partial frames
    # remain in the buffer until the next callback completes them.
    def drain_data_frames(pending)
      buf = pending.frame_buffer

      while buf.bytesize >= 2
        type_byte = buf.getbyte(0)
        if type_byte < 0x40
          type = type_byte
          type_len = 1
        else
          type, type_len = Protocol.decode_varint_str(buf, 0)
          break if type_len == 0
        end

        len_byte = buf.getbyte(type_len)
        break unless len_byte
        if len_byte < 0x40
          length = len_byte
          length_len = 1
        else
          length, length_len = Protocol.decode_varint_str(buf, type_len)
          break if length_len == 0
        end

        header_len = type_len + length_len
        total = header_len + length

        # Incomplete frame — wait for more data
        break if buf.bytesize < total

        if type == Protocol::FRAME_DATA
          pending.body.write(buf.byteslice(header_len, length))
        end
        # Skip non-DATA frames (e.g. unknown extension frames)

        buf = buf.byteslice(total..-1) || "".b
      end

      pending.frame_buffer = buf
    end

    def accept_webtransport(connection, connection_handle, stream_id, stream_handle, headers, early_data: false)
      # Draft-16 §5.1 forbids concurrent sessions without session flow control.
      manager = @webtransport.for(connection_handle)
      if manager.routable_sessions.any?
        manager.reject_stream(stream_id, stream_handle, error_code: Protocol::H3_REQUEST_REJECTED)
        return
      end

      Quicsilver.logger.debug(
        "WebTransport CONNECT stream=#{stream_id} path=#{headers[":path"].inspect} " \
        "authority=#{headers[":authority"].inspect} headers=#{headers.inspect}"
      )

      stream = Transport::InboundStream.new(stream_id)
      stream.stream_handle = stream_handle

      session = WebTransportSession.new(
        connection: connection,
        stream: stream,
        headers: headers
      )

      dispatch_webtransport_to_rack(connection, connection_handle, stream_id, headers, session, early_data: early_data)
      session if session.accepted?
    rescue => e
      Quicsilver.logger.error("WebTransport error: #{e.class} - #{e.message}")
      nil
    end

    def dispatch_webtransport_to_rack(connection, connection_handle, stream_id, headers, session, early_data: false)
      request_context = connection.request_context(stream_id: stream_id)
      rack_context = Rack::Context.new(
        stream_id: stream_id,
        early_data: early_data,
        webtransport: session,
        metadata: request_context
      )

      request, _body = @request_handler.adapter.build_request(
        headers,
        remote_address: connection.remote_address,
        remote_port: connection.remote_port,
        transport_context: request_context,
        rack_context: rack_context
      )

      Quicsilver.logger.debug(
        "Dispatching WebTransport to Rack stream=#{stream_id} " \
        "method=#{request.method.inspect} path=#{request.path.inspect} early_data=#{early_data.inspect}"
      )

      @webtransport.for(connection_handle).register(session)
      response = @request_handler.adapter.call(request)

      Quicsilver.logger.debug(
        "WebTransport Rack response stream=#{stream_id} status=#{response.status.inspect} " \
        "accepted=#{session.accepted?}"
      )

      if session.accepted?
        connection.track_client_stream(stream_id)
      else
        @webtransport.for(connection_handle).unregister(stream_id)
        session.reject!(response.status)
      end
    end

    def route_wt_uni_stream(connection_handle, stream_id, stream_handle, payload, fin: false)
      # After Connection strips the 0x54 stream type, payload is:
      # [session_id varint][data...]
      # Reuse the same prefix parser — format is identical minus the type byte.
      @webtransport.for(connection_handle).route_unidirectional_stream(stream_id, stream_handle, payload, fin: fin)
    rescue => e
      Quicsilver.logger.error("WebTransport uni stream error: #{e.class} - #{e.message}")
    end

    # Accept an incoming WebTransport stream — parse prefix and route to session
    def accept_webtransport_stream(connection_handle, stream_id, stream_handle, payload)
      @webtransport.for(connection_handle).accept_bidi_stream(stream_id, stream_handle, payload)
    rescue => e
      Quicsilver.logger.error("WebTransport stream error: #{e.class} - #{e.message}")
    end

    def contains_headers_frame?(data)
      return false if data.nil? || data.bytesize < 2
      data.getbyte(0) == Protocol::FRAME_HEADERS
    end
  end
end
