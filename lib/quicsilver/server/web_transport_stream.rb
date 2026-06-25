# frozen_string_literal: true

module Quicsilver
  class Server
    # A reliable bidirectional stream within a WebTransport session.
    #
    # Streams are opened by either the client or server. Data is reliable
    # and ordered — unlike datagrams, nothing is dropped.
    #
    # Usage:
    #   while data = stream.read
    #     stream.write("echo: #{data}")
    #   end
    #
    #   # Server-initiated:
    #   stream = session.open_stream
    #   stream.write("server push")
    #   stream.close
    #
    class WebTransportStream
      attr_reader :stream_id, :session

      def initialize(session:, stream:, stream_id:, direction: :bidi)
        @session = session
        @stream = stream
        @stream_id = stream_id
        @direction = direction
        @open = true
        @closed = false
        # Receive-side queue backing stream.read. The write side sends directly
        # to the underlying QUIC stream; this queue only buffers DATA payloads
        # received from the peer. Plain Ruby Queue is enough here; if
        # Falcon/Async needs a fiber-aware wait primitive later, this is the
        # seam to revisit.
        @input = build_receive_queue
        @buffer = "".b
      end

      def write(data)
        raise "Cannot write to a receive-only stream" if @direction == :receive_only
        return unless @open
        frame = Protocol.build_frame(Protocol::FRAME_DATA, data.to_s.b)
        @stream.send(frame)
      end

      def close
        return if @closed
        @stream.close_write rescue nil
        notify_close
      end

      # Read the next DATA payload from this WebTransport stream. Blocks until
      # data arrives or the stream closes. Returns nil when closed. This is
      # currently chunk-oriented: each call returns one received DATA payload.
      def read
        @input.pop
      end

      # Iterate over received DATA payloads until the stream closes. The
      # returned Enumerator has unknown size because this is a live transport
      # source.
      def each
        return enum_for(:each) unless block_given?

        while (data = read)
          yield data
        end
      end

      def open?
        @open
      end

      # Called by Server when data arrives on this stream. :nodoc:
      def receive_data(data)
        @buffer << data

        # Extract complete DATA frames from the buffer
        while @buffer.bytesize >= 2
          type_byte = @buffer.getbyte(0)
          break unless type_byte

          type, type_len = Protocol.decode_varint_str(@buffer, 0)
          break if type_len == 0

          length, length_len = Protocol.decode_varint_str(@buffer, type_len)
          break if length_len == 0

          header_len = type_len + length_len
          break if @buffer.bytesize < header_len + length

          if type == Protocol::FRAME_DATA
            payload = @buffer.byteslice(header_len, length)
            @input.push(payload) if @open
          end

          @buffer = @buffer.byteslice(header_len + length..-1) || "".b
        end
      end

      # Called by Server when the stream is reset or closed. :nodoc:
      def notify_close
        return if @closed
        @closed = true
        @open = false
        @input.close
      end

      private

      def build_receive_queue
        Queue.new
      end
    end
  end
end
