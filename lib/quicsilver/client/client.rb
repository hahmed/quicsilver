# frozen_string_literal: true

module Quicsilver
  class Client
    include Protocol::ControlStreamParser

    attr_reader :hostname, :port, :unsecure, :connection_timeout, :request_timeout
    attr_reader :peer_goaway_id, :peer_settings, :peer_max_field_section_size

    StreamFailedToOpenError = Class.new(StandardError)
    GoAwayError = Class.new(StandardError)

    FINISHED_EVENTS = %w[RECEIVE_FIN RECEIVE STREAM_RESET STOP_SENDING].freeze

    DEFAULT_REQUEST_TIMEOUT = 30  # seconds
    DEFAULT_CONNECTION_TIMEOUT = 5000  # ms

    def initialize(hostname, port = 4433, **options)
      @hostname = hostname
      @port = port
      @unsecure = options.fetch(:unsecure, true)
      @connection_timeout = options.fetch(:connection_timeout, DEFAULT_CONNECTION_TIMEOUT)
      @request_timeout = options.fetch(:request_timeout, DEFAULT_REQUEST_TIMEOUT)
      @max_body_size = options[:max_body_size]
      @max_header_size = options[:max_header_size]

      @connection_data = nil
      @connected = false
      @connection_start_time = nil

      @response_buffers = {}  # stream_id => binary data
      @inflight = {}  # handle => { request:, stream_id: }
      @mutex = Mutex.new

      # Server control stream state
      @peer_settings = {}
      @peer_max_field_section_size = nil
      @peer_goaway_id = nil
      @settings_received = false
      @control_stream_id = nil
      @uni_stream_types = {}
    end

    # --- Class-level API (automatic pooling) ---
    #
    #   Quicsilver::Client.get("example.com", 4433, "/users")
    #   Quicsilver::Client.post("example.com", 4433, "/data", body: json)
    #
    class << self
      attr_writer :pool

      def pool
        @pool ||= ConnectionPool.new
      end

      def close_pool
        @pool&.close
        @pool = nil
      end

      # Fire-and-forget HTTP methods with automatic pooling.
      %i[get post patch delete head put].each do |method|
        define_method(method) do |hostname, port, path, headers: {}, body: nil, **options, &block|
          request(hostname, port, method, path, headers: headers, body: body, **options, &block)
        end
      end

      def request(hostname, port, method, path, headers: {}, body: nil, **options, &block)
        client = pool.checkout(hostname, port, **options)
        client.public_send(method, path, headers: headers, body: body, &block)
      ensure
        pool.checkin(client) if client
      end
    end

    # Disconnect and close the underlying QUIC connection.
    def disconnect
      return unless @connected

      @connected = false

      @mutex.synchronize do
        @inflight.each_value { |entry| entry[:request].fail(0, "Connection closed") }
        @inflight.clear
        @response_buffers.clear
      end

      close_connection
    end

    # Instance-level HTTP methods. Auto-connects on first use.
    #
    #   client = Quicsilver::Client.new("example.com", 4433)
    #   client.get("/users")   # connects automatically
    #   client.post("/data", body: json)
    #
    %i[get post patch delete head put].each do |method|
      define_method(method) do |path, headers: {}, body: nil, &block|
        req = build_request(method.to_s.upcase, path, headers: headers, body: body)
        block ? block.call(req) : req.response
      end
    end

    def draining?
      !@peer_goaway_id.nil?
    end

    def receive_control_data(stream_id, data) # :nodoc:
      buf = @uni_stream_types.key?(stream_id) ? data : identify_and_strip_stream_type(stream_id, data)
      return if buf.nil? || buf.empty?

      case @uni_stream_types[stream_id]
      when :control
        parse_control_frames(buf)
      end
    end

    def build_request(method, path, headers: {}, body: nil)
      ensure_connected!
      raise GoAwayError, "Connection is draining (GOAWAY received)" if draining?

      stream = open_stream
      raise StreamFailedToOpenError unless stream

      request = Request.new(self, stream)
      @mutex.synchronize do
        @inflight[stream.handle] = { request: request, stream_id: nil }
      end

      send_to_stream(stream, method, path, headers, body)

      request
    end

    def connected?
      @connected && @connection_data && connection_alive?
    end

    # Returns QUIC transport statistics (RTT, packet counts, congestion, etc.)
    # from MsQuic's QUIC_STATISTICS_V2. Returns nil when not connected.
    def stats
      return nil unless @connected && @connection_data
      Transport::ConnectionStats.from_hash(Quicsilver.connection_statistics(@connection_data[0]))
    rescue
      nil
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

    # :nodoc:
    def open_connection
      return self if @connected

      Quicsilver.open_connection
      config = Quicsilver.create_configuration(@unsecure)
      raise ConnectionError, "Failed to create configuration" if config.nil?

      start_connection(config)
      @connected = true
      @connection_start_time = Time.now
      send_control_stream
      Quicsilver.event_loop.start

      self
    rescue => e
      cleanup_failed_connection
      raise e.is_a?(ConnectionError) || e.is_a?(TimeoutError) ? e : ConnectionError.new("Connection failed: #{e.message}")
    ensure
      Quicsilver.close_configuration(config) if config
    end

    # :nodoc:
    def close_connection
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      @connection_data = nil
      @connected = false
    end

    # Called directly by C extension via dispatch_to_ruby
    def handle_stream_event(stream_id, event, data, _early_data) # :nodoc:
      return unless FINISHED_EVENTS.include?(event)

      # Server unidirectional streams (control, QPACK) — process incrementally
      if (stream_id & 0x02) != 0 && (event == "RECEIVE" || event == "RECEIVE_FIN")
        begin
          receive_control_data(stream_id, data)
        rescue Protocol::FrameError => e
          Quicsilver.logger.error("Control stream error: #{e.message} (0x#{e.error_code.to_s(16)})")
        end
        return
      end

      @mutex.synchronize do
        case event
        when "RECEIVE"
          # Data is prepended with [stream_handle(8)] — extract handle and payload
          event_obj = Transport::StreamEvent.new(data, "RECEIVE")
          if (entry = @inflight[event_obj.handle])
            entry[:stream_id] ||= stream_id
          end
          (@response_buffers[stream_id] ||= "".b) << event_obj.data
          # Strip 1xx informational HEADERS frames (e.g. 103 Early Hints).
          # The final response will follow — keep buffering.
          strip_informational_frames!(stream_id)

        when "RECEIVE_FIN"
          event = Transport::StreamEvent.new(data, "RECEIVE_FIN")
          buffer = @response_buffers.delete(stream_id)
          full_data = (buffer || "".b) + event.data

          # Strip any remaining informational frames before parsing final response
          full_data = strip_informational_data(full_data)

          response_parser = Protocol::ResponseParser.new(full_data, max_body_size: @max_body_size,
            max_header_size: @max_header_size)
          response_parser.parse

          response = {
            status: response_parser.status,
            headers: response_parser.headers,
            body: response_parser.body&.read || "",
            trailers: response_parser.trailers || {}
          }

          entry = @inflight.delete(event.handle)
          entry[:request]&.complete(response) if entry

        when "STREAM_RESET"
          event = Transport::StreamEvent.new(data, "STREAM_RESET")
          entry = @inflight.delete(event.handle)
          entry[:request]&.fail(event.error_code, "Stream reset by peer") if entry

        when "STOP_SENDING"
          event = Transport::StreamEvent.new(data, "STOP_SENDING")
          entry = @inflight.delete(event.handle)
          entry[:request]&.fail(event.error_code, "Peer sent STOP_SENDING") if entry
        end
      end
    rescue => e
      Quicsilver.logger.error("Error handling client stream: #{e.class} - #{e.message}")
      Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
    end

    private

    def ensure_connected!
      return if @connected
      open_connection
    end

    def start_connection(config)
      connection_handle, context_handle = create_connection
      unless Quicsilver.start_connection(connection_handle, config, @hostname, @port)
        cleanup_failed_connection
        raise ConnectionError, "Failed to start connection"
      end

      result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)
      handle_connection_result(result)
    end

    def create_connection
      @connection_data = Quicsilver.create_connection(self)
      raise ConnectionError, "Failed to create connection" if @connection_data.nil?

      @connection_data
    end

    def cleanup_failed_connection
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      @connection_data = nil
      @connected = false
    end

    def open_stream
      handle = Quicsilver.open_stream(@connection_data, false)
      Transport::Stream.new(handle)
    end

    def open_unidirectional_stream
      handle = Quicsilver.open_stream(@connection_data, true)
      Transport::Stream.new(handle)
    end

    def send_control_stream
      @control_stream = open_unidirectional_stream
      @control_stream.send(Protocol.build_control_stream)

      [0x02, 0x03].each do |type|
        stream = open_unidirectional_stream
        stream.send([type].pack("C"))
      end
    end

    def handle_connection_result(result)
      if result.key?("error")
        cleanup_failed_connection
        raise ConnectionError, "Connection failed: status 0x#{result['status'].to_s(16)}, code: #{result['code']}"
      elsif result.key?("timeout")
        cleanup_failed_connection
        raise TimeoutError, "Connection timed out after #{@connection_timeout}ms"
      end
    end

    def connection_alive?
      return false unless (info = Quicsilver.connection_status(@connection_data[1]))
      info["connected"] && !info["failed"]
    rescue
      false
    end

    def send_to_stream(stream, method, path, headers, body)
      encoded_response = Protocol::RequestEncoder.new(
        method: method,
        path: path,
        scheme: "https",
        authority: authority,
        headers: headers,
        body: body
      ).encode

      # RFC 9114 §4.2.2: Enforce server's SETTINGS_MAX_FIELD_SECTION_SIZE
      if @peer_max_field_section_size
        header_size = estimate_header_size(method, path, headers)
        if header_size > @peer_max_field_section_size
          @mutex.synchronize { @inflight.delete(stream.handle) }
          raise Error, "Request headers (#{header_size} bytes) exceed server's max field section size (#{@peer_max_field_section_size})"
        end
      end

      result = stream.send(encoded_response, fin: true)

      unless result
        @mutex.synchronize { @inflight.delete(stream.handle) }
        raise Error, "Failed to send request"
      end
    end

    # RFC 9114 §4.2.2: Estimate header field section size.
    # Each field: name length + value length + 32 bytes overhead.
    def estimate_header_size(method, path, headers)
      size = 0
      # Pseudo-headers
      size += ":method".bytesize + method.to_s.bytesize + 32
      size += ":path".bytesize + path.to_s.bytesize + 32
      size += ":scheme".bytesize + 5 + 32  # "https"
      size += ":authority".bytesize + authority.bytesize + 32
      # Regular headers
      headers.each { |name, value| size += name.to_s.bytesize + value.to_s.bytesize + 32 }
      size
    end

    # Strip leading 1xx informational HEADERS frames from data.
    # RFC 9114 §4.1: Interim responses (1xx) precede the final response.
    def strip_informational_data(data)
      skip = Protocol::FrameReader.skip_while(data) do |type, payload|
        type == Protocol::FRAME_HEADERS &&
          (status = peek_status(payload)) && status >= 100 && status < 200
      end
      skip > 0 ? data.byteslice(skip..-1) || "".b : data
    end

    def strip_informational_frames!(stream_id)
      buf = @response_buffers[stream_id]
      return unless buf && buf.bytesize >= 2

      @response_buffers[stream_id] = strip_informational_data(buf)
    end

    # Decode just the :status pseudo-header from a QPACK header block.
    PEEK_DECODER = Protocol::Qpack::HeaderBlockDecoder.new

    def peek_status(qpack_payload)
      PEEK_DECODER.decode(qpack_payload) do |name, value|
        return value.to_i if name == ":status"
      end
      nil
    rescue
      nil
    end

    # Identify stream type from first byte(s), strip it, return remaining data.
    # Returns nil for unknown/ignored stream types.
    def identify_and_strip_stream_type(stream_id, data)
      stream_type, type_len = Protocol.decode_varint(data.bytes, 0)
      return nil if type_len == 0

      case stream_type
      when 0x00 # Control stream
        raise Protocol::FrameError, "Duplicate control stream" if @control_stream_id
        @control_stream_id = stream_id
        @uni_stream_types[stream_id] = :control
      when 0x02 # QPACK encoder stream
        @uni_stream_types[stream_id] = :qpack_encoder
      when 0x03 # QPACK decoder stream
        @uni_stream_types[stream_id] = :qpack_decoder
      else
        # Unknown unidirectional stream types MUST be ignored (RFC 9114 §6.2)
        @uni_stream_types[stream_id] = :unknown
        return nil
      end

      data[type_len..] || "".b
    end

    def on_settings_received(settings)
      @peer_settings.merge!(settings)
      @peer_max_field_section_size = settings[0x06] if settings.key?(0x06)
    end

    # RFC 9114 §5.2: After receiving GOAWAY, fail any in-flight requests
    # on streams at or above the GOAWAY stream ID — the server won't process them.
    def on_goaway_received(goaway_stream_id)
      fail_requests_above_goaway(goaway_stream_id)
    end

    def fail_requests_above_goaway(goaway_stream_id)
      @mutex.synchronize do
        @inflight.each do |handle, entry|
          sid = entry[:stream_id]
          next unless sid && sid >= goaway_stream_id
          @inflight.delete(handle)
          entry[:request]&.fail(0, "GOAWAY: server will not process stream #{sid}")
        end
      end
    end
  end
end
