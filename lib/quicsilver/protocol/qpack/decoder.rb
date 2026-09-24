# frozen_string_literal: true

require_relative "huffman"

module Quicsilver
  module Protocol
    module Qpack
      module Decoder
        # Decode a QPACK string literal (RFC 9204 Section 4.1.2)
        # Returns [string, bytes_consumed]
        # String-based variant: accepts a binary String instead of byte array
        def decode_qpack_string_from_str(data, offset)
          first = data.getbyte(offset)
          huffman = (first & 0x80) != 0

          length = first & 0x7F
          len_bytes = 1
          if length == 0x7F
            multiplier = 1
            while offset + len_bytes < data.bytesize
              next_byte = data.getbyte(offset + len_bytes)
              len_bytes += 1
              length += (next_byte & 0x7F) * multiplier
              break if (next_byte & 0x80) == 0
              multiplier *= 128
            end
          end

          data_offset = offset + len_bytes
          raw = data.byteslice(data_offset, length)

          str = if huffman
            Huffman.decode(raw) || raw
          else
            raw
          end

          [str, len_bytes + length]
        end

        # Byte-array variant. Results are not cached: the input is mutable, so
        # keying on identity or object_id returns a stale decode after an
        # in-place edit. Production decoding uses the String variant above.
        def decode_qpack_string(bytes, offset)
          return decode_qpack_string_from_str(bytes, offset) if bytes.is_a?(String)

          first = bytes[offset]
          huffman = (first & 0x80) != 0

          # Inline 7-bit prefix integer decode to avoid method call
          length = first & 0x7F
          len_bytes = 1
          if length == 0x7F
            multiplier = 1
            while offset + len_bytes < bytes.size
              next_byte = bytes[offset + len_bytes]
              len_bytes += 1
              length += (next_byte & 0x7F) * multiplier
              break if (next_byte & 0x80) == 0
              multiplier *= 128
            end
          end

          data_offset = offset + len_bytes
          raw = bytes[data_offset, length].pack("C*")

          str = if huffman
            Huffman.decode(raw) || raw
          else
            raw
          end

          [str, len_bytes + length].freeze
        end

        # String-based prefix integer decoding
        def decode_prefix_integer_str(data, offset, prefix_bits, pattern_mask)
          max_prefix = (1 << prefix_bits) - 1
          first_byte = data.getbyte(offset)
          value = first_byte & max_prefix
          bytes_consumed = 1

          if value == max_prefix
            multiplier = 1
            loop do
              return [value, bytes_consumed] if offset + bytes_consumed >= data.bytesize
              next_byte = data.getbyte(offset + bytes_consumed)
              bytes_consumed += 1
              value += (next_byte & 0x7F) * multiplier
              break if (next_byte & 0x80) == 0
              multiplier *= 128
            end
          end

          [value, bytes_consumed]
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
end
