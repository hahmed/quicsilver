# frozen_string_literal: true

require_relative "huffman_code"

module Quicsilver
  module Qpack
    module Decoder
      # Decode a QPACK string literal (RFC 9204 Section 4.1.2)
      # Returns [string, bytes_consumed]
      def decode_qpack_string(bytes, offset)
        first = bytes[offset]
        huffman = (first & 0x80) != 0

        # Decode length using 7-bit prefix integer
        length, len_bytes = decode_prefix_integer(bytes, offset, 7, 0x80)
        offset += len_bytes

        raw = bytes[offset, length].pack("C*")

        str = if huffman
          HuffmanCode.decode(raw) || raw
        else
          raw
        end

        [str, len_bytes + length]
      end

      # RFC 7541 prefix integer decoding
      # Returns [value, bytes_consumed]
      def decode_prefix_integer(bytes, offset, prefix_bits, pattern_mask)
        max_prefix = (1 << prefix_bits) - 1

        first_byte = bytes[offset]
        value = first_byte & max_prefix
        bytes_consumed = 1

        if value == max_prefix
          multiplier = 1
          loop do
            return [value, bytes_consumed] if offset + bytes_consumed >= bytes.size

            next_byte = bytes[offset + bytes_consumed]
            bytes_consumed += 1

            value += (next_byte & 0x7F) * multiplier
            break if (next_byte & 0x80) == 0

            multiplier *= 128
          end
        end

        [value, bytes_consumed]
      end
    end
  end
end
