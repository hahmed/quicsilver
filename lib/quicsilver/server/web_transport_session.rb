# frozen_string_literal: true

module Quicsilver
  class Server
    # A WebTransport session opened via Extended CONNECT (RFC 9220).
    #
    # WebTransport provides two messaging modes on the same session:
    # - Datagrams: unreliable, unordered (live cursors, typing indicators)
    # - Streams: reliable, ordered (chat messages, RPC)
    #
    # Usage:
    #   server.on_webtransport do |session|
    #     session.accept!
    #     session.on_datagram { |data| session.send_datagram("echo: #{data}") }
    #     session.on_stream { |stream|
    #       stream.on_data { |data| stream.write("echo: #{data}") }
    #       stream.on_close { puts "stream closed" }
    #     }
    #     session.on_close { puts "session closed" }
    #   end
    #
    class WebTransportSession
      attr_reader :path, :authority, :headers, :connection, :stream_id

      # WebTransport stream frame types (draft-ietf-webtrans-http3)
      WT_STREAM_BIDI = 0x41
      WT_STREAM_UNI = 0x54

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
        @datagram_callback = nil
        @stream_callback = nil
        @uni_stream_callback = nil
        @close_callback = nil
        @streams = {}  # stream_id => WebTransportStream
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
        Quicsilver.datagram_send(@connection.data, data.to_s.b)
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

      def open?
        @open
      end

      # Look up a stream by ID within this session.
      def stream(stream_id)
        @streams[stream_id]
      end

      # Close the session.
      def close
        return unless @open
        @open = false
        @stream.reset(Protocol::H3_NO_ERROR) rescue nil
        notify_close
      end

      # Called by Server when a datagram arrives for this session.
      def receive_datagram(data) # :nodoc:
        @datagram_callback&.call(data)
      end

      # Called by Server when the CONNECT stream is reset/closed.
      def notify_close # :nodoc:
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
    end
  end
end
