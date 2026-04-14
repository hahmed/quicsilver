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

    # Tracks an in-flight streaming request between RECEIVE and RECEIVE_FIN.
    # The stream handle arrives at RECEIVE_FIN; the worker thread waits for it.
    PendingStream = Struct.new(:connection, :body, :request, :stream_id, :stream_handle, :handle_ready, :frame_buffer, keyword_init: true) do
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

    DEFAULT_THREAD_POOL_SIZE = 5
    DEFAULT_QUEUE_MULTIPLIER = 4
    DEFAULT_MAX_CONNECTIONS = 100

    def initialize(port = 4433, address: "0.0.0.0", app: nil, server_configuration: nil, threads: DEFAULT_THREAD_POOL_SIZE, max_queue_size: nil, max_connections: DEFAULT_MAX_CONNECTIONS)
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
      @handler_threads = []
      @handler_mutex = Mutex.new
      @thread_pool_size = threads
      @max_queue_size = max_queue_size || threads * DEFAULT_QUEUE_MULTIPLIER
      @work_queue = Queue.new
      @max_connections = max_connections
      @cancelled_streams = Set.new
      @cancelled_mutex = Mutex.new
      @pending_streams = {}  # stream_id => PendingStream (for streaming dispatch)
      @pending_mutex = Mutex.new

      # Mode controls app wrapping, not the code path:
      #   :rack (default) — app is a Rack app, wrap with Protocol::Rack::Adapter
      #   :falcon        — app is a native protocol-http app, use directly
      protocol_app = case @server_configuration.mode
        when :rack then ::Protocol::Rack::Adapter.new(@app)
        when :falcon then @app
        else ::Protocol::Rack::Adapter.new(@app)
      end

      @request_handler = RequestHandler.new(
        app: protocol_app,
        configuration: @server_configuration,
        request_registry: @request_registry,
        cancelled_streams: @cancelled_streams,
        cancelled_mutex: @cancelled_mutex
      )

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
      @connections.each_value { |c| c.send_goaway(Protocol::MAX_STREAM_ID) }

      # Phase 2: Drain in-flight requests
      drain(timeout: timeout)

      # Grace period: let pending responses reach clients
      sleep [0.5, timeout * 0.1].min

      # Log any requests that didn't complete
      unless @request_registry.empty?
        @request_registry.active_requests.each do |stream_id, req|
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

        connection = Transport::Connection.new(connection_handle, connection_data)
        @connections[connection_handle] = connection
        connection.setup_http3_streams

      when STREAM_EVENT_CONNECTION_CLOSED
        @connections.delete(connection_handle)&.streams&.clear
        Quicsilver.close_server_connection(connection_handle)

      when STREAM_EVENT_SEND_COMPLETE
        # Buffer cleanup handled in C extension
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
        else
          @cancelled_mutex.synchronize { @cancelled_streams.add(stream_id) }
          pending = @pending_mutex.synchronize { @pending_streams.delete(stream_id) }
          pending&.body&.close(RuntimeError.new("Stream #{stream_id} reset by peer"))
          @request_registry.complete(stream_id)
        end
      when STREAM_EVENT_STOP_SENDING
        return unless @connections[connection_handle]
        event = Transport::StreamEvent.new(data, "STOP_SENDING")
        Quicsilver.logger.debug("Stream #{stream_id} stop sending requested with error code: 0x#{event.error_code.to_s(16)}")
        @cancelled_mutex.synchronize { @cancelled_streams.add(stream_id) }
        Quicsilver.stream_reset(event.handle, Protocol::H3_REQUEST_CANCELLED)
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

    def handle_receive(connection, connection_handle, stream_id, data, early_data: false)
      # Unidirectional streams (control, QPACK) must be processed incrementally —
      # they never send FIN, so waiting for RECEIVE_FIN would mean never parsing.
      if (stream_id & 0x02) != 0  # unidirectional
        begin
          connection.receive_unidirectional_data(stream_id, data)
        rescue Protocol::FrameError => e
          Quicsilver.logger.error("Control stream error: #{e.message} (0x#{e.error_code.to_s(16)})")
          Quicsilver.connection_shutdown(connection_handle, e.error_code, false) rescue nil
        end
      else
        handle_bidi_receive(connection, connection_handle, stream_id, data, early_data: early_data)
      end
    end

    def handle_bidi_receive(connection, connection_handle, stream_id, data, early_data: false)
      pending = @pending_mutex.synchronize { @pending_streams[stream_id] }
      if pending
        # Subsequent RECEIVE — append to frame buffer and extract complete DATA payloads.
        # MsQuic splits data at arbitrary boundaries, so frames may span callbacks.
        pending.frame_buffer << data
        drain_data_frames(pending)
      elsif contains_headers_frame?(data)
        dispatch_streaming(connection, connection_handle, stream_id, data, early_data: early_data)
      else
        connection.buffer_data(stream_id, data)
      end
    end

    def handle_receive_fin(connection, connection_handle, stream_id, data, early_data: false)
      event = Transport::StreamEvent.new(data, "RECEIVE_FIN")

      pending = @pending_mutex.synchronize { @pending_streams[stream_id] }
      if pending
        complete_streaming_request(pending, event)
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
        dispatch_request(connection, stream, early_data: early_data)
      else
        begin
          connection.handle_unidirectional_stream(stream)
        rescue Protocol::FrameError => e
          Quicsilver.logger.error("Control stream error: #{e.message} (0x#{e.error_code.to_s(16)})")
          Quicsilver.connection_shutdown(connection_handle, e.error_code, false) rescue nil
        end
      end
    end

    def dispatch_request(connection, stream, early_data: false)
      if @work_queue.size >= @max_queue_size
        Quicsilver.logger.warn("Work queue full (#{@max_queue_size}), rejecting request")
        connection.send_error(stream, 503, "Service Unavailable") if stream.writable?
      else
        @work_queue.push([connection, stream, early_data])
      end
    end

    def start_worker_pool
      @thread_pool_size.times do
        thread = Thread.new do
          while (work = @work_queue.pop)
            break if work == :shutdown

            if work.is_a?(Array) && work[0] == :streaming
              handle_streaming_request(work[1])
            else
              connection, stream, early_data = work
              @request_handler.call(connection, stream, early_data: early_data)
            end
          end
        end
        @handler_mutex.synchronize { @handler_threads << thread }
      end
    end

    # Streaming dispatch: parse headers from first RECEIVE, dispatch immediately.
    # Body data arrives via subsequent RECEIVE events into StreamInput.
    def dispatch_streaming(connection, connection_handle, stream_id, data, early_data: false)
      parser = Protocol::RequestParser.new(
        data,
        max_header_size: @server_configuration.max_header_size,
        max_header_count: @server_configuration.max_header_count,
        max_frame_payload_size: @server_configuration.max_frame_payload_size
      )
      parser.parse
      parser.validate_headers!

      headers = parser.headers
      return if headers.empty?

      method = headers[":method"]

      if @server_configuration.early_data_policy == :reject &&
         early_data && !RequestHandler::SAFE_METHODS.include?(method)
        Quicsilver.logger.debug("Rejected 0-RTT #{method} on stream #{stream_id} (no stream handle to send 425)")
        return
      end

      request, body = @request_handler.adapter.build_request(headers)
      request.headers.add("quicsilver-early-data", early_data.to_s)

      # Feed body data from the first RECEIVE.
      # The parser consumed complete frames (HEADERS + any complete DATA frames).
      if body
        # Complete DATA frames the parser extracted
        if parser.body && parser.body.size > 0
          parser.body.rewind
          body_data = parser.body.read
          body.write(body_data) unless body_data.empty?
        end
      end

      pending = PendingStream.new(
        connection: connection,
        body: body,
        request: request,
        stream_id: stream_id
      )

      # Unconsumed bytes go into the frame buffer for incremental parsing
      remainder = data.byteslice(parser.bytes_consumed..-1)
      if remainder && remainder.bytesize > 0
        pending.frame_buffer << remainder
        drain_data_frames(pending)
      end
      @pending_mutex.synchronize { @pending_streams[stream_id] = pending }

      connection.track_client_stream(stream_id)
      @request_registry.track(stream_id, connection_handle,
        path: headers[":path"] || "/", method: method || "GET")

      if @work_queue.size >= @max_queue_size
        Quicsilver.logger.warn("Work queue full (#{@max_queue_size}), rejecting request")
        body&.close
        @pending_mutex.synchronize { @pending_streams.delete(stream_id) }
      else
        @work_queue.push([:streaming, pending])
      end
    rescue Protocol::FrameError => e
      Quicsilver.logger.error("Frame error: #{e.message}")
      Quicsilver.connection_shutdown(connection_handle, e.error_code, false) rescue nil
    rescue Protocol::MessageError => e
      Quicsilver.logger.error("Message error on stream #{stream_id}: #{e.message}")
    rescue => e
      Quicsilver.logger.error("Error in streaming dispatch: #{e.class} - #{e.message}")
    end

    def handle_streaming_request(pending)
      response = @request_handler.adapter.call(pending.request)

      # Wait for RECEIVE_FIN to provide the stream handle
      stream_handle = pending.wait_for_handle(timeout: 30)
      unless stream_handle
        Quicsilver.logger.error("Timed out waiting for stream handle on stream #{pending.stream_id}")
        return
      end

      return if cancelled_stream?(pending.stream_id)

      response_headers = {}
      response.headers&.each { |name, value| response_headers[name] = value }

      if !response_headers.key?("content-length") && response.body&.length
        response_headers["content-length"] = response.body.length.to_s
      end

      stream = Transport::InboundStream.new(pending.stream_id)
      stream.stream_handle = stream_handle

      pending.connection.send_response(stream, response.status, response_headers, response.body,
        head_request: pending.request.method == "HEAD")
      @request_registry.complete(pending.stream_id)
    rescue => e
      Quicsilver.logger.error("Streaming request error: #{e.class} - #{e.message}")
      if pending.stream_handle
        stream = Transport::InboundStream.new(pending.stream_id)
        stream.stream_handle = pending.stream_handle
        pending.connection.send_error(stream, 500, "Internal Server Error") if stream.writable?
      end
    ensure
      @pending_mutex.synchronize { @pending_streams.delete(pending.stream_id) }
      @request_registry.complete(pending.stream_id) if @request_registry.include?(pending.stream_id)
      @cancelled_mutex.synchronize { @cancelled_streams.delete(pending.stream_id) }
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

    # Heuristic: check if raw data starts with an HTTP/3 HEADERS frame (type 0x01).
    # QUIC typically delivers complete frames, but if this misidentifies data,
    # the parser will fail safely in dispatch_streaming's rescue handlers.
    def contains_headers_frame?(data)
      return false if data.nil? || data.bytesize < 2
      data.getbyte(0) == Protocol::FRAME_HEADERS
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
  end
end
