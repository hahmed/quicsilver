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
      MAX_CLOSE_MESSAGE_LENGTH = 1024

      # Parse a bidirectional WebTransport stream prefix:
      # [type=0x41 varint][session_id varint][data...]
      # Returns [session_id, remainder] or nil if malformed.
      def self.parse_stream_prefix(payload)
        type, type_len = Protocol.decode_varint_str(payload, 0)
        return nil unless type == WT_STREAM_BIDI && type_len > 0

        session_id, sid_len = Protocol.decode_varint_str(payload, type_len)
        return nil if sid_len == 0

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
      def self.parse_uni_stream_data(payload)
        session_id, sid_len = Protocol.decode_varint_str(payload, 0)
        return nil if sid_len == 0
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
        @stream_callback = nil
        @uni_stream_callback = nil
        @close_callback = nil
        @streams = {}  # stream_id => WebTransportStream
        @connect_buffer = "".b
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
        raise "Session not open" unless @open

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
        stream = @connection.open_stream
        prefix = Protocol.encode_varint(WT_STREAM_BIDI) +
                 Protocol.encode_varint(@stream_id)
        stream.send(prefix)

        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream.stream_id
        )
        @streams[wt_stream.stream_id] = wt_stream
        wt_stream
      end

      # Register a callback for incoming unidirectional streams (client → server, read-only).
      def on_uni_stream(&block)
        @uni_stream_callback = block
      end

      # Open a server-initiated unidirectional stream to the client (write-only).
      def open_uni_stream
        raise "Session not accepted" unless @accepted
        stream = @connection.open_stream(unidirectional: true)
        prefix = Protocol.encode_varint(WT_STREAM_UNI) +
                 Protocol.encode_varint(@stream_id)
        stream.send(prefix)

        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream.stream_id,
          direction: :send_only
        )
        @streams[wt_stream.stream_id] = wt_stream
        wt_stream
      end

      # Register a callback for session close.
      def on_close(&block)
        @close_callback = block
      end

      def accepted?
        @accepted
      end

      def open?
        @open
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
          @stream.reset(Protocol::H3_NO_ERROR) rescue nil
        end

        notify_close
      end

      # Called by Server when data arrives on the CONNECT/session stream. :nodoc:
      def receive_connect_data(data)
        @connect_buffer << data if data && !data.empty?

        loop do
          type, type_len = Protocol.decode_varint_str(@connect_buffer, 0)
          return if type_len == 0

          length, length_len = Protocol.decode_varint_str(@connect_buffer, type_len)
          return if length_len == 0

          header_len = type_len + length_len
          return if @connect_buffer.bytesize < header_len + length

          payload = @connect_buffer.byteslice(header_len, length) || "".b
          handle_capsule(type, payload)
          @connect_buffer = @connect_buffer.byteslice(header_len + length..-1) || "".b
        end
      end

      # Called by Server when a datagram arrives for this session.
      def receive_datagram(data) # :nodoc:
        @datagram_callback&.call(data)
      end

      # Called by Server when the CONNECT stream is reset/closed.
      def notify_close # :nodoc:
        Quicsilver.logger.debug("WebTransport session #{@stream_id} notify_close")
        @open = false
        @streams.each_value(&:notify_close)
        @streams.clear
        @close_callback&.call
      end

      # Called by Server when a new stream with our session ID arrives.
      def add_stream(stream_handle, stream_id) # :nodoc:
        stream = Transport::Stream.new(stream_handle)
        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream_id
        )
        @streams[stream_id] = wt_stream
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
        @streams[stream_id] = wt_stream
        @uni_stream_callback&.call(wt_stream)
        wt_stream
      end

      # Called when a stream within this session is reset.
      def remove_stream(stream_id) # :nodoc:
        stream = @streams.delete(stream_id)
        stream&.notify_close
      end

      private

      def handle_capsule(type, payload)
        case type
        when WT_CLOSE_SESSION
          code = payload.bytesize >= 4 ? payload.byteslice(0, 4).unpack1("N") : 0
          reason = payload.bytesize > 4 ? payload.byteslice(4..-1).to_s : ""
          Quicsilver.logger.debug("WebTransport session #{@stream_id} received close capsule code=#{code} reason=#{reason.inspect}")
          notify_close
        else
          # Unknown capsules are ignored, matching HTTP Capsule extensibility.
        end
      end

      def write_close_reason(code, reason)
        reason = reason.to_s
        reason = reason.byteslice(0, MAX_CLOSE_MESSAGE_LENGTH) if reason.bytesize > MAX_CLOSE_MESSAGE_LENGTH
        payload = [code].pack("N") + reason.b
        capsule = Protocol.encode_varint(WT_CLOSE_SESSION) +
                  Protocol.encode_varint(payload.bytesize) +
                  payload
        @stream.send(capsule, fin: false)
      rescue
        # Best-effort — connection may already be gone
      end
    end
  end
end
