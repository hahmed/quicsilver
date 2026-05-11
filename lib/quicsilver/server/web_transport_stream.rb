# frozen_string_literal: true

module Quicsilver
  class Server
    # A reliable bidirectional stream within a WebTransport session.
    #
    # Streams are opened by either the client or server. Data is reliable
    # and ordered — unlike datagrams, nothing is dropped.
    #
    # Usage:
    #   session.on_stream do |stream|
    #     stream.on_data { |data| stream.write("echo: #{data}") }
    #     stream.on_close { cleanup }
    #   end
    #
    #   # Server-initiated:
    #   stream = session.open_stream
    #   stream.write("server push")
    #   stream.close
    #
    class WebTransportStream
      attr_reader :stream_id, :session

      def initialize(session:, stream:, stream_id:)
        @session = session
        @stream = stream
        @stream_id = stream_id
        @open = true
        @data_callback = nil
        @close_callback = nil
        @buffer = "".b
      end

      def write(data)
        return unless @open
        frame = Protocol.build_frame(Protocol::FRAME_DATA, data.to_s.b)
        @stream.send(frame)
      end

      def close
        return unless @open
        @open = false
        @stream.send("".b, fin: true) rescue nil
        @close_callback&.call
      end

      def on_data(&block)
        @data_callback = block
      end

      def on_close(&block)
        @close_callback = block
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
            @data_callback&.call(payload)
          end

          @buffer = @buffer.byteslice(header_len + length..-1) || "".b
        end
      end

      # Called by Server when the stream is reset or closed. :nodoc:
      def notify_close
        @open = false
        @close_callback&.call
      end
    end
  end
end
