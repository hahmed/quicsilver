# frozen_string_literal: true

require_relative "frame_parser"

module Quicsilver
  module Protocol
    # Incrementally yields CONNECT DATA payloads without waiting for whole
    # frames. Unknown frame payloads are skipped as bytes arrive.
    class ConnectStreamDecoder
      def initialize
        @buffer = "".b
        @frame_type = nil
        @frame_remaining = nil
      end

      # A caller may break after a terminal capsule. Unprocessed bytes remain
      # available to buffered? so it can reject data following that capsule.
      def each(data)
        @buffer << data if data
        until @buffer.empty?
          break unless @frame_remaining || read_frame_header

          chunk = consume_payload
          yield chunk if @frame_type == FRAME_DATA
        end
      end

      def buffered?
        !@buffer.empty?
      end

      def finish!
        if buffered? || @frame_remaining
          raise FrameError.new("Truncated HTTP/3 frame", error_code: H3_FRAME_ERROR)
        end
      end

      def clear
        @buffer.clear
        @frame_remaining = nil
      end

      private

      def read_frame_header
        type, type_length = Protocol.decode_varint_str(@buffer, 0)
        return false if type_length == 0
        length, length_length = Protocol.decode_varint_str(@buffer, type_length)
        return false if length_length == 0

        # RFC 9114 §4.4 forbids known non-DATA frames after CONNECT,
        # including HEADERS trailers; these are connection errors.
        if FrameParser::CONTROL_ONLY_SET.key?(type) ||
            FrameParser::HTTP2_RESERVED_FRAMES.key?(type) ||
            [FRAME_HEADERS, FRAME_PUSH_PROMISE, FRAME_PRIORITY_UPDATE].include?(type)
          raise FrameError, "Frame not allowed on CONNECT"
        end

        @frame_type = type
        @frame_remaining = length
        @buffer = @buffer.byteslice(type_length + length_length..) || "".b
        true
      end

      def consume_payload
        count = [@frame_remaining, @buffer.bytesize].min
        chunk = @buffer.byteslice(0, count)
        @buffer = @buffer.byteslice(count..) || "".b
        @frame_remaining -= count
        @frame_remaining = nil if @frame_remaining.zero?
        chunk
      end
    end
  end
end
