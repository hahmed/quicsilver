# frozen_string_literal: true

module Quicsilver
  class Server
    # A WebTransport session opened via Extended CONNECT (RFC 9220).
    #
    # WebTransport provides two messaging modes on the same session:
    # - Datagrams: unreliable, unordered (live cursors, typing indicators)
    # - Streams: reliable, ordered (chat messages, RPC)
    #
    # Usage from Rack:
    #   session = env["quicsilver.context"].webtransport
    #   session.accept!
    #   session.on_datagram { |data| session.send_datagram("echo: #{data}") }
    #
    class WebTransportSession
      attr_reader :path, :authority, :headers, :connection, :stream_id

      # WebTransport stream types (draft-ietf-webtrans-http3), matching aioquic/Chrome.
      WT_STREAM_BIDI = Protocol::WebTransport::BIDI_STREAM_TYPE
      WT_STREAM_UNI = Protocol::WebTransport::UNI_STREAM_TYPE
      WT_CLOSE_SESSION = Protocol::WebTransport::CLOSE_SESSION_CAPSULE
      WT_DRAIN_SESSION = Protocol::WebTransport::DRAIN_SESSION_CAPSULE

      # Why a session ended. A clean close with no capsule is code 0 and an
      # empty reason (draft-ietf-webtrans-http3-16 §6).
      #
      # `remote` distinguishes the peer hanging up from us closing, which the
      # wire format does not carry but applications need for reconnect logic.
      CloseInfo = Data.define(:code, :reason, :remote) do
        def remote? = remote
        def local? = !remote
      end

      # WT_CLOSE_SESSION payload layout (§6):
      #
      #   [error code: 4 bytes, network order][reason: UTF-8, ≤ 1024 bytes]
      ERROR_CODE_BYTES = 4
      MAX_CLOSE_MESSAGE_LENGTH = 1024

      # Parse a bidirectional WebTransport stream prefix:
      # [type=0x41 varint][session_id varint][data...]
      # Returns [session_id, remainder] or nil if malformed.
      # A session id is the stream id of the CONNECT request that established
      # it, so it is always a client-initiated bidirectional stream
      # (draft-ietf-webtrans-http3-16 §4). Anything else cannot name a session.
      def self.valid_session_id?(session_id)
        session_id % 4 == 0
      end

      def self.parse_stream_prefix(payload)
        type, type_len = Protocol.decode_varint_str(payload, 0)
        return nil unless type == WT_STREAM_BIDI && type_len > 0

        session_id, sid_len = Protocol.decode_varint_str(payload, type_len)
        return nil if sid_len == 0
        return nil unless valid_session_id?(session_id)

        [session_id, payload.byteslice((type_len + sid_len)..-1) || "".b]
      end

      # Route an incoming WebTransport stream to the right session.
      def self.accept_stream(sessions, stream_id, stream_handle, payload)
        session_id, initial_data = parse_stream_prefix(payload)
        return unless session_id

        session = sessions[session_id]
        return unless session

        wt_stream = session.add_stream(stream_handle, stream_id)
        wt_stream.receive_data(initial_data) if initial_data && !initial_data.empty?
        wt_stream
      end

      # A bare FIN means a clean close; a CLOSE capsule must contain its
      # four-byte code and a valid, bounded UTF-8 reason (draft-16 §6).
      def self.parse_close_payload(payload)
        raise Protocol::Capsule::ParseError, "Truncated close code" if payload.bytesize < ERROR_CODE_BYTES
        code = payload.unpack1("N")
        reason = payload.byteslice(ERROR_CODE_BYTES..).dup.force_encoding(Encoding::UTF_8)
        unless reason.bytesize <= MAX_CLOSE_MESSAGE_LENGTH && reason.valid_encoding?
          raise Protocol::Capsule::ParseError, "Invalid close reason"
        end
        CloseInfo.new(code: code, reason: reason, remote: true)
      end

      def self.build_close_payload(code, reason)
        unless code.is_a?(Integer) && code.between?(0, 0xffff_ffff)
          raise ArgumentError, "Close code must be an unsigned 32-bit integer"
        end
        [code].pack("N") + truncate_reason(reason).b
      end

      # Truncate only at a UTF-8 character boundary (draft-16 §6).
      def self.truncate_reason(reason, limit = MAX_CLOSE_MESSAGE_LENGTH)
        reason = reason.to_s
        reason = reason.b.dup.force_encoding(Encoding::UTF_8) if reason.encoding == Encoding::ASCII_8BIT
        reason = reason.encode(Encoding::UTF_8)
        raise ArgumentError, "Close reason must be valid UTF-8" unless reason.valid_encoding?
        return reason if reason.bytesize <= limit

        truncated = reason.byteslice(0, limit)
        truncated = truncated.byteslice(0, truncated.bytesize - 1) until truncated.valid_encoding?
        truncated
      end

      def self.parse_uni_stream_data(payload)
        session_id, sid_len = Protocol.decode_varint_str(payload, 0)
        return nil if sid_len == 0
        return nil unless valid_session_id?(session_id)

        [session_id, payload.byteslice(sid_len..-1) || "".b]
      end

      def initialize(connection:, stream:, headers:)
        @connection = connection
        @stream = stream
        @stream_id = stream.stream_id
        @path = headers[":path"]
        @authority = headers[":authority"]
        @headers = headers
        @accepted = false
        @open = false
        @datagram_callback = nil
        @drain_callback = nil
        @stream_callback = nil
        @uni_stream_callback = nil
        @close_callback = nil
        @streams = {}  # stream_id => WebTransportStream
        @starting_streams = {}
        @streams_mutex = Mutex.new
        @connect_buffer = "".b
        @connect_frame_buffer = "".b
        @connect_frame_remaining = nil
        @connect_send_finished = false
        @received_close = false
        @connect_failed = false
        @closed = false
      end

      def stream_manager=(manager)
        @streams_mutex.synchronize do
          @stream_manager = manager
          @streams.each_key { |stream_id| manager.register_stream(stream_id, @stream_id) }
          @starting_streams.each_value { |stream| manager.register_starting_stream(stream) }
        end
      end

      # Accept the session — sends 200 HEADERS on the CONNECT stream.
      def accept!
        raise IOError, "Session closed" if @closed
        return if @accepted

        frame = Protocol.build_headers_frame([[:":status", "200"]])
        @stream.send(frame, fin: false)
        @accepted = true
        @open = true
      end

      # Send a datagram to the client (unreliable, no retransmission).
      def send_datagram(data)
        raise "Session not accepted" unless @accepted
        raise "Session not open" unless accepts_datagrams?

        Quicsilver.datagram_send(@connection.data, Protocol::Datagram.encode(@stream_id, data))
      end

      # Register a callback for datagrams from the client.
      def on_datagram(&block)
        @datagram_callback = block
      end

      # Register a callback for incoming streams from the client.
      def on_stream(&block)
        @stream_callback = block
      end

      # Open a server-initiated bidirectional stream to the client.
      def open_stream
        open_outgoing_stream(unidirectional: false)
      end

      # Register a callback for incoming unidirectional streams (client → server, read-only).
      def on_uni_stream(&block)
        @uni_stream_callback = block
      end

      # Open a server-initiated unidirectional stream to the client (write-only).
      def open_uni_stream
        open_outgoing_stream(unidirectional: true)
      end

      # Register a callback for session close.
      def on_close(&block)
        @close_callback = block
      end

      # The peer is asking us to wind this session down. Advisory: the session
      # stays usable, and the application decides when to close (draft-16 §4.7).
      #
      #   session.on_drain { stop_accepting_work }
      def on_drain(&block)
        @drain_callback = block
      end

      # Ask the peer to wind the session down. Does not close it.
      def drain!
        @stream.send(Protocol.build_frame(Protocol::FRAME_DATA, Protocol::Capsule.encode(WT_DRAIN_SESSION, "")), fin: false)
      rescue
        # Best-effort — connection may already be gone
      end

      def accepted?
        @accepted
      end

      def open?
        @open && !@closed
      end

      def closed?
        @closed
      end

      def routable?
        !@closed
      end

      def accepts_new_streams?
        open?
      end

      def accepts_datagrams?
        open?
      end

      def reject!(status = 403, headers = {})
        return if @accepted || @rejected
        @rejected = true

        response_headers = [[":status", status.to_i.to_s]]
        headers.each { |name, value| response_headers << [name.to_s.downcase, value.to_s] }
        @stream.send(Protocol.build_headers_frame(response_headers), fin: true)
        @open = false
      end

      # Look up a stream by ID within this session.
      def stream(stream_id)
        @streams[stream_id]
      end

      # Close the session with an optional error code and message.
      # Sends a WT_CLOSE_SESSION capsule (RFC draft-ietf-webtrans-http3)
      # on the CONNECT stream before closing.
      def close(code: 0, reason: "")
        return if closed?
        # Conversion can invoke application code or raise. Do it before
        # changing lifecycle state so invalid input leaves the session usable.
        payload = self.class.build_close_payload(code, reason)
        was_open = @streams_mutex.synchronize do
          was_open = @open
          @open = false
          was_open
        end

        if was_open
          capsule = Protocol::Capsule.encode(WT_CLOSE_SESSION, payload)
          finish_connect(Protocol.build_frame(Protocol::FRAME_DATA, capsule))
        end

        notify_close(code: code, reason: reason, remote: false)
      end

      # Decode the HTTP/3 body before parsing capsules. DATA frame boundaries
      # and QUIC receive boundaries need not align with capsule boundaries.
      # Unknown frame payloads are skipped incrementally, without retaining them.
      def receive_connect_stream_data(data, fin: false)
        return if @connect_failed
        if @received_close
          if data && !data.empty?
            return handle_capsule_error(Protocol::Capsule::ParseError.new("Stream data after close capsule"))
          elsif fin && @connect_frame_remaining
            raise Protocol::FrameError.new("Truncated HTTP/3 frame", error_code: Protocol::H3_FRAME_ERROR)
          end
        end
        return if closed?
        @connect_frame_buffer << data if data
        until @connect_frame_buffer.empty?
          unless @connect_frame_remaining
            type, type_length = Protocol.decode_varint_str(@connect_frame_buffer, 0)
            break if type_length == 0
            length, length_length = Protocol.decode_varint_str(@connect_frame_buffer, type_length)
            break if length_length == 0
            if Protocol::FrameParser::CONTROL_ONLY_SET.key?(type) ||
                Protocol::FrameParser::HTTP2_RESERVED_FRAMES.key?(type) ||
                [Protocol::FRAME_HEADERS, Protocol::FRAME_PUSH_PROMISE, Protocol::FRAME_PRIORITY_UPDATE].include?(type)
              raise Protocol::FrameError, "Frame not allowed on CONNECT"
            end
            @connect_frame_type = type
            @connect_frame_remaining = length
            @connect_frame_buffer = @connect_frame_buffer.byteslice(type_length + length_length..) || "".b
          end
          count = [@connect_frame_remaining, @connect_frame_buffer.bytesize].min
          chunk = @connect_frame_buffer.byteslice(0, count)
          @connect_frame_buffer = @connect_frame_buffer.byteslice(count..) || "".b
          @connect_frame_remaining -= count
          @connect_frame_remaining = nil if @connect_frame_remaining.zero?
          receive_connect_data(chunk) if @connect_frame_type == Protocol::FRAME_DATA
          return if @connect_failed
          if @received_close
            unless @connect_frame_buffer.empty?
              handle_capsule_error(Protocol::Capsule::ParseError.new("Stream data after close capsule"))
            end
            break
          end
        end
        if fin
          unless @connect_frame_buffer.empty? && @connect_frame_remaining.nil?
            raise Protocol::FrameError.new("Truncated HTTP/3 frame", error_code: Protocol::H3_FRAME_ERROR)
          end
          receive_connect_fin("")
        end
      rescue Protocol::FrameError => error
        @connect_failed = true
        @connect_frame_buffer.clear
        begin
          @connection.shutdown(error.error_code)
        ensure
          notify_close
        end
      end

      # Capsule bytes extracted from the CONNECT HTTP message body. :nodoc:
      def receive_connect_data(data)
        return if @connect_failed
        if @received_close && data && !data.empty?
          return handle_capsule_error(Protocol::Capsule::ParseError.new("Data after close capsule"))
        end
        return if closed?
        @connect_buffer << data if data && !data.empty?

        while (capsule = Protocol::Capsule.parse(@connect_buffer))
          type, payload, @connect_buffer = capsule
          handle_capsule(type, payload)
          if @received_close
            handle_capsule_error(Protocol::Capsule::ParseError.new("Data after close capsule")) unless @connect_buffer.empty?
            break
          end
        end
      rescue Protocol::Capsule::ParseError => error
        handle_capsule_error(error)
      end

      # Called by Server when the CONNECT/session stream receives FIN. :nodoc:
      def receive_connect_fin(data)
        receive_connect_data(data)
        handle_capsule_error(Protocol::Capsule::ParseError.new("Truncated capsule")) unless @connect_buffer.empty?
        finish_connect if @accepted && !@connect_failed
        notify_close
      end

      # Called by Server when a datagram arrives for this session.
      def receive_datagram(data) # :nodoc:
        @datagram_callback&.call(data)
      end

      # Called by Server when the CONNECT stream is reset/closed.
      #
      # Idempotent: subsequent calls are a no-op. This matters because the FIN
      # and capsule-error paths both fan into notify_close, and a CLOSE_SESSION
      # capsule followed by FIN would otherwise fire @close_callback twice and
      # re-walk an already-cleared @streams map.
      def notify_close(code: 0, reason: "", remote: true) # :nodoc:
        streams = @streams_mutex.synchronize do
          return if @closed
          @closed = true
          @open = false
          streams = @streams.values + @starting_streams.values
          @streams.clear
          @starting_streams.clear
          streams
        end

        Quicsilver.logger.debug("WebTransport session #{@stream_id} notify_close")
        begin
          terminate_streams(streams)
        ensure
          @close_callback&.call(CloseInfo.new(code: code, reason: reason, remote: remote))
        end
      end

      # Called by Server when a new stream with our session ID arrives.
      def add_stream(stream_handle, stream_id) # :nodoc:
        stream = Transport::Stream.new(stream_handle)
        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream_id
        )
        return wt_stream unless register_stream(wt_stream)
        @stream_callback&.call(wt_stream)
        wt_stream
      end

      # Route data to the right stream.
      def route_stream_data(stream_id, data) # :nodoc:
        @streams[stream_id]&.receive_data(data)
      end

      # Called by Server when an incoming uni stream arrives.
      def add_uni_stream(stream_handle, stream_id) # :nodoc:
        stream = Transport::Stream.new(stream_handle)
        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream_id,
          direction: :receive_only
        )
        return wt_stream unless register_stream(wt_stream)
        @uni_stream_callback&.call(wt_stream)
        wt_stream
      end

      def stream_started(stream, stream_id)
        @streams_mutex.synchronize do
          starting = @starting_streams.delete(stream.stream_handle)
          stream.notify_start(stream_id)
          @stream_manager&.register_stream(stream_id, @stream_id)
          @streams[stream_id] = stream if starting && !@closed
        end
      end

      def remove_starting_stream(handle)
        stream = @streams_mutex.synchronize { @starting_streams.delete(handle) }
        stream&.notify_close
      end

      # Called when a stream within this session is reset.
      # `error_code` is the raw HTTP/3 code from a peer RESET_STREAM, so the
      # stream can report it to the application (§4.4). nil for an ordinary
      # close, where there is no code to deliver.
      def remove_stream(stream_id, error_code: nil) # :nodoc:
        stream = @streams_mutex.synchronize { @streams.delete(stream_id) }
        return unless stream

        error_code ? stream.notify_reset(error_code) : stream.notify_close
      end

      private

      def open_outgoing_stream(unidirectional:)
        raise "Session not accepted" unless @accepted
        raise "Session not open" unless accepts_new_streams?

        stream = @connection.open_stream(unidirectional: unidirectional)
        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream.stream_id,
          direction: unidirectional ? :send_only : :bidi
        )
        raise "Session not open" unless register_stream(wt_stream, outgoing: true)

        type = unidirectional ? WT_STREAM_UNI : WT_STREAM_BIDI
        stream.send(Protocol.encode_varint(type) + Protocol.encode_varint(@stream_id))
        @stream_manager&.stream_started(stream.stream_id, stream.handle)
        wt_stream
      rescue StandardError
        discard_outgoing_stream(wt_stream) if wt_stream
        raise
      end

      def discard_outgoing_stream(stream)
        @streams_mutex.synchronize do
          @streams.delete(stream.stream_id)
          @starting_streams.delete(stream.stream_handle)
          @stream_manager&.discard_starting_stream(stream.stream_handle)
        end
        stream.abort(Protocol::WebTransport::SESSION_GONE) if stream.open?
      end

      def register_stream(stream, outgoing: false)
        registered = @streams_mutex.synchronize do
          if stream.stream_id
            @stream_manager&.register_stream(stream.stream_id, @stream_id)
          else
            @stream_manager&.register_starting_stream(stream)
          end
          next false if @closed || (outgoing && !@open)

          if stream.stream_id
            @streams[stream.stream_id] = stream
          else
            @starting_streams[stream.stream_handle] = stream
          end
          true
        end
        stream.abort(Protocol::WebTransport::SESSION_GONE) unless registered
        registered
      end

      def terminate_streams(streams)
        failure = nil
        streams.each do |stream|
          stream.abort(Protocol::WebTransport::SESSION_GONE)
        rescue StandardError => error
          failure ||= error
        end
        raise failure if failure
      end

      def handle_capsule(type, payload)
        case type
        when WT_CLOSE_SESSION
          closed_with = self.class.parse_close_payload(payload)
          Quicsilver.logger.debug(
            "WebTransport session #{@stream_id} received close capsule " \
            "code=#{closed_with.code} reason=#{closed_with.reason.inspect}"
          )
          # draft-16 §6 requires the recipient to close or reset CONNECT.
          # Finish our send side without discarding any queued response bytes.
          @received_close = true
          if @accepted
            finish_connect
          else
            abort_connect(Protocol::H3_REQUEST_REJECTED)
          end
          notify_close(**closed_with.to_h)
        when WT_DRAIN_SESSION
          # Advisory only. The session stays open and usable; it is up to the
          # application to wind down (draft-16 §4.7).
          Quicsilver.logger.debug("WebTransport session #{@stream_id} received drain capsule")
          @drain_callback&.call
        else
          # Unknown capsules are ignored, matching HTTP Capsule extensibility.
        end
      end

      def handle_capsule_error(error)
        return if @connect_failed
        @connect_failed = true
        Quicsilver.logger.debug("WebTransport session #{@stream_id} capsule error: #{error.message}")
        @connect_buffer.clear
        @connect_frame_buffer.clear
        abort_connect(Protocol::H3_MESSAGE_ERROR)
        notify_close
      end

      def abort_connect(code)
        # FIN may already be acknowledged, making a send-only RESET a no-op.
        # Also stop receiving so a peer cannot hold failed CONNECT streams open.
        @stream.abort(code)
      rescue StandardError
        # The native stream may already have gone; still clean up locally.
      end

      def finish_connect(data = "")
        @streams_mutex.synchronize do
          return if @connect_send_finished
          @connect_send_finished = true
        end

        # Successful submission preserves queued bytes and sends FIN. If native
        # submission fails on a live stream, abort both directions as a fallback.
        @stream.send(data, fin: true)
      rescue StandardError
        abort_connect(Protocol::H3_INTERNAL_ERROR)
      end
    end
  end
end
