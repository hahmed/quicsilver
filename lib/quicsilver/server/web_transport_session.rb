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
    #   while data = session.read_datagram
    #     session.send_datagram("echo: #{data}")
    #   end
    #
    class WebTransportSession
      attr_reader :path, :authority, :headers, :connection, :stream_id

      # WebTransport stream frame types (draft-ietf-webtrans-http3)
      WT_STREAM_BIDI = 0x41
      WT_STREAM_UNI = 0x54
      WT_CLOSE_SESSION = 0x2843
      MAX_CLOSE_MESSAGE_LENGTH = 1024

      def self.webtransport_stream?(data)
        return false if data.nil? || data.bytesize < 2
        type, _ = Protocol.decode_varint_str(data, 0)
        type == WT_STREAM_BIDI || type == WT_STREAM_UNI
      end

      # Parse the WebTransport stream prefix: [type varint][session_id varint]
      # Returns [session_id, remainder] or nil if malformed.
      def self.parse_stream_prefix(payload)
        offset = 0
        _type, type_len = Protocol.decode_varint_str(payload, offset)
        return nil if type_len == 0
        offset += type_len
        session_id, sid_len = Protocol.decode_varint_str(payload, offset)
        return nil if sid_len == 0
        offset += sid_len
        [session_id, payload.byteslice(offset..-1) || "".b]  # [session_id, initial_data]
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

      # Find a stream by ID across all sessions.
      def self.find_stream(sessions, stream_id)
        sessions.each_value do |session|
          stream = session.stream(stream_id)
          return stream if stream
        end
        nil
      end

      # Find the session that owns a given stream.
      def self.find_session_for_stream(sessions, stream_id)
        sessions.each_value do |session|
          return session if session.stream(stream_id)
        end
        nil
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
        @closed = false
        # Receive-side queues backing the IO-shaped API. Streams opened by
        # this endpoint are returned directly from open_stream/open_uni_stream;
        # streams opened by the peer are accepted through these queues.
        @datagram_queue = Transport::DatagramQueue.new
        @stream_accept_queue = Transport::BlockingQueue.new
        @uni_stream_accept_queue = Transport::BlockingQueue.new
        @streams = {}  # stream_id => WebTransportStream
      end

      # Accept the session — sends 200 HEADERS on the CONNECT stream.
      def accept!
        raise "Session closed" if @closed
        return if @accepted

        frame = Protocol.build_headers_frame([[:":status", "200"]])
        @stream.send(frame, fin: false)
        @accepted = true
        @open = true
      end

      # Send a datagram to the client (unreliable, no retransmission).
      def send_datagram(data)
        raise "Session not accepted" unless @accepted
        Quicsilver.datagram_send(@connection.data, data.to_s.b)
      end

      # Read the next datagram from the peer. Blocks until a datagram arrives
      # or the session closes. Returns nil when closed. Datagrams are unreliable
      # and backed by a bounded queue; excess datagrams are dropped.
      def read_datagram
        @datagram_queue.pop
      end

      # Accept the next peer-initiated bidirectional stream. Blocks until a
      # stream arrives or the session closes. Returns nil when closed.
      def accept_stream
        @stream_accept_queue.pop
      end

      # Accept the next peer-initiated unidirectional stream. Blocks until a
      # stream arrives or the session closes. Returns nil when closed.
      def accept_uni_stream
        @uni_stream_accept_queue.pop
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
        return if @closed
        if @open
          write_close_reason(code, reason)
          @stream.reset(Protocol::H3_NO_ERROR) rescue nil
        end
        notify_close
      end

      # Called by Server when a datagram arrives for this session.
      def receive_datagram(data) # :nodoc:
        @datagram_queue.push(data) if @open
      end

      # Number of inbound datagrams dropped because the receive queue was full.
      def datagrams_dropped
        @datagram_queue.dropped
      end

      # Called by Server when the CONNECT stream is reset/closed.
      def notify_close # :nodoc:
        return if @closed
        @closed = true
        @open = false
        @datagram_queue.close
        @stream_accept_queue.close
        @uni_stream_accept_queue.close
        @streams.each_value(&:notify_close)
        @streams.clear
      end

      # Called by Server when a new stream with our session ID arrives.
      def add_stream(stream_handle, stream_id) # :nodoc:
        stream = Transport::Stream.new(stream_handle)
        wt_stream = WebTransportStream.new(
          session: self, stream: stream, stream_id: stream_id
        )
        @streams[stream_id] = wt_stream
        @stream_accept_queue.push(wt_stream)
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
        @uni_stream_accept_queue.push(wt_stream)
        wt_stream
      end

      # Called when a stream within this session is reset.
      def remove_stream(stream_id) # :nodoc:
        stream = @streams.delete(stream_id)
        stream&.notify_close
      end

      private

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
