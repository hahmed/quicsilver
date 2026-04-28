# frozen_string_literal: true

module Quicsilver
  module Protocol
    # Extracts HTTP/3 frames from a byte buffer.
    # Yields (type, payload, offset) per frame. Returns total bytes consumed.
    # Existing callers using |type, payload| are unaffected — offset is ignored.
    #
    # Usage:
    #   FrameReader.each(buffer) do |type, payload|
    #     case type
    #     when FRAME_HEADERS then ...
    #     when FRAME_DATA then ...
    #     end
    #   end
    #
    # With offset (for early exit via throw/catch):
    #   strip = FrameReader.skip_while(data) { |type, payload| ... }
    #   data = data.byteslice(strip..) if strip > 0
    module FrameReader
      def self.each(buffer)
        offset = 0
        buf_size = buffer.bytesize

        while offset < buf_size
          break if buf_size - offset < 2

          # Inline single-byte varint fast path (covers frame types 0x00-0x3F)
          type_byte = buffer.getbyte(offset)
          if type_byte < 0x40
            type = type_byte
            type_len = 1
          else
            type, type_len = Protocol.decode_varint_str(buffer, offset)
            break if type_len == 0
          end

          len_byte = buffer.getbyte(offset + type_len)
          if len_byte < 0x40
            length = len_byte
            length_len = 1
          else
            length, length_len = Protocol.decode_varint_str(buffer, offset + type_len)
            break if length_len == 0
          end

          header_len = type_len + length_len
          break if buf_size < offset + header_len + length

          payload = buffer.byteslice(offset + header_len, length)
          offset += header_len + length

          yield type, payload, offset
        end

        offset
      end

      # Skip leading frames while the block returns true.
      # Returns the byte offset of the first frame that returned false (or 0).
      #
      #   skip = FrameReader.skip_while(data) do |type, payload|
      #     type == FRAME_HEADERS && informational?(payload)
      #   end
      #   data = data.byteslice(skip..) if skip > 0
      def self.skip_while(buffer)
        skip_to = 0

        catch(:stop) do
          each(buffer) do |type, payload, offset|
            if yield(type, payload)
              skip_to = offset
            else
              throw :stop
            end
          end
        end

        skip_to
      end
    end
  end
end
