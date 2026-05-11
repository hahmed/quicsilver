# frozen_string_literal: true

module Quicsilver
  class Server
    # A WebTransport session opened via Extended CONNECT (RFC 9220).
    #
    # WebTransport provides two messaging modes on the same session:
    # - Datagrams: unreliable, unordered (live cursors, typing indicators)
    # - Streams: reliable, ordered (chat messages, RPC) — not yet implemented
    #
    # Usage:
    #   server.on_webtransport do |session|
    #     session.accept!
    #     session.on_datagram { |data| session.send_datagram("echo: #{data}") }
    #     session.on_close { puts "session closed" }
    #   end
    #
    class WebTransportSession
      attr_reader :path, :authority, :headers, :connection, :stream_id

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
        @close_callback = nil
      end

      # Accept the session — sends 200 HEADERS on the CONNECT stream.
      def accept!
        return if @accepted

        frame = Protocol.build_headers_frame([[:":status", "200"]])
        Quicsilver.send_stream(@stream.stream_handle, frame, false)
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

      # Register a callback for session close.
      def on_close(&block)
        @close_callback = block
      end

      def open?
        @open
      end

      # Close the session.
      def close
        return unless @open
        @open = false
        Quicsilver.stream_reset(@stream.stream_handle, Protocol::H3_NO_ERROR) rescue nil
        notify_close
      end

      # Called by Server when a datagram arrives for this session.
      def receive_datagram(data) # :nodoc:
        @datagram_callback&.call(data)
      end

      # Called by Server when the CONNECT stream is reset/closed.
      def notify_close # :nodoc:
        @open = false
        @close_callback&.call
      end
    end
  end
end
