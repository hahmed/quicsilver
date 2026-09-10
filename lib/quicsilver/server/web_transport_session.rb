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

      # Parse uni stream data after Connection strips the 0x54 type byte.
      # Payload is [session_id varint][data...]
      # Cut a close reason to at most `limit` bytes without splitting a
      # character. draft-ietf-webtrans-http3-16 §6 requires truncation on a
      # UTF-8 boundary; a receiver seeing invalid UTF-8 MUST reset the stream
      # with H3_MESSAGE_ERROR.
      # Read a WT_CLOSE_SESSION payload. A short or absent payload counts as a
      # clean close: §6 makes a bare stream close equivalent to code 0 with an
      # empty reason. Always remote — a payload only exists because a peer sent
      # one.
      def self.parse_close_payload(payload)
        code = payload.byteslice(0, ERROR_CODE_BYTES)&.unpack1("N") || 0
        # +"" because nil.to_s is frozen and force_encoding mutates.
        reason = +payload.byteslice(ERROR_CODE_BYTES..-1).to_s

        CloseInfo.new(
          code: code,
          reason: reason.force_encoding(Encoding::UTF_8),
          remote: true
        )
      end

      # Inverse of parse_close_payload, so the layout is defined in one place.
      def self.build_close_payload(code, reason)
        [code].pack("N") + truncate_reason(reason).b
      end

      def self.truncate_reason(reason, limit = MAX_CLOSE_MESSAGE_LENGTH)
        reason = reason.to_s
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
        @connect_buffer = "".b
        @closed = false
      end

      def stream_manager=(manager)
        @stream_manager = manager
        @streams.each_key { |stream_id| manager.register_stream(stream_id) }
      end

      # Accept the session — sends 200 HEADERS on the CONNECT stream.
      def accept!
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
        raise "Session not accepted" unless @accepted
        raise "Session not open" unless accepts_new_streams?
        stream = @connection.open_stream
        prefix = Protocol.encode_varint(WT_STREAM_BIDI) +
                 Protocol.encode_varint(@stream_id)
        stream.send(prefix)

        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream.stream_id
        )
        register_stream(wt_stream)
        wt_stream
      end

      # Register a callback for incoming unidirectional streams (client → server, read-only).
      def on_uni_stream(&block)
        @uni_stream_callback = block
      end

      # Open a server-initiated unidirectional stream to the client (write-only).
      def open_uni_stream
        raise "Session not accepted" unless @accepted
        raise "Session not open" unless accepts_new_streams?
        stream = @connection.open_stream(unidirectional: true)
        prefix = Protocol.encode_varint(WT_STREAM_UNI) +
                 Protocol.encode_varint(@stream_id)
        stream.send(prefix)

        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream.stream_id,
          direction: :send_only
        )
        register_stream(wt_stream)
        wt_stream
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
        @stream.send(Protocol::Capsule.encode(WT_DRAIN_SESSION, ""), fin: false)
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
        was_open = @open
        @open = false

        if was_open
          write_close_reason(code, reason)
          @stream.reset(Protocol::H3_NO_ERROR)
        end

        notify_close(code: code, reason: reason, remote: false)
      end

      # Called by Server when data arrives on the CONNECT/session stream. :nodoc:
      def receive_connect_data(data)
        @connect_buffer << data if data && !data.empty?

        while (capsule = Protocol::Capsule.parse(@connect_buffer))
          type, payload, @connect_buffer = capsule
          handle_capsule(type, payload)
        end
      rescue Protocol::Capsule::ParseError => error
        handle_capsule_error(error)
      end

      # Called by Server when the CONNECT/session stream receives FIN. :nodoc:
      def receive_connect_fin(data)
        receive_connect_data(data)
        handle_capsule_error(Protocol::Capsule::ParseError.new("Truncated capsule")) unless @connect_buffer.empty?
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
        return if @closed
        @closed = true

        Quicsilver.logger.debug("WebTransport session #{@stream_id} notify_close")
        @open = false
        begin
          terminate_streams
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
        register_stream(wt_stream)
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
        register_stream(wt_stream)
        @uni_stream_callback&.call(wt_stream)
        wt_stream
      end

      # Called when a stream within this session is reset.
      # `error_code` is the raw HTTP/3 code from a peer RESET_STREAM, so the
      # stream can report it to the application (§4.4). nil for an ordinary
      # close, where there is no code to deliver.
      def remove_stream(stream_id, error_code: nil) # :nodoc:
        stream = @streams.delete(stream_id)
        return unless stream

        error_code ? stream.notify_reset(error_code) : stream.notify_close
      end

      private

      def register_stream(stream)
        @stream_manager&.register_stream(stream.stream_id)
        @streams[stream.stream_id] = stream
      end

      def terminate_streams
        streams = @streams.values
        @streams.clear
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
        Quicsilver.logger.debug("WebTransport session #{@stream_id} capsule error: #{error.message}")
        @connect_buffer = "".b
        @stream.reset(Protocol::H3_DATAGRAM_ERROR)
        notify_close
      end

      def write_close_reason(code, reason)
        payload = self.class.build_close_payload(code, reason)
        @stream.send(Protocol::Capsule.encode(WT_CLOSE_SESSION, payload), fin: false)
      rescue
        # Best-effort — connection may already be gone
      end
    end
  end
end
