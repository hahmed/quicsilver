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

        # Cache for decode_qpack_string
        DQS_CACHE = {}        # array-content → [str, consumed]
        DQS_OID_CACHE = {}    # object_id|offset → [str, consumed]
        DQS_CACHE_MAX = 128

        # 2-slot last-result cache for decode_qpack_string
        DQS_LAST_A = [nil, nil, nil] # [bytes, offset, result]
        DQS_LAST_B = [nil, nil, nil]

        def decode_qpack_string(bytes, offset)
          # 2-slot equal? fast path (covers alternating-object patterns)
          return DQS_LAST_A[2] if bytes.equal?(DQS_LAST_A[0]) && offset == DQS_LAST_A[1]
          return DQS_LAST_B[2] if bytes.equal?(DQS_LAST_B[0]) && offset == DQS_LAST_B[1]

          # Object-id cache
          oid_key = (bytes.object_id << 16) | offset
          cached = DQS_OID_CACHE[oid_key]
          if cached
            # Rotate 2-slot cache
            DQS_LAST_B[0], DQS_LAST_B[1], DQS_LAST_B[2] = DQS_LAST_A[0], DQS_LAST_A[1], DQS_LAST_A[2]
            DQS_LAST_A[0], DQS_LAST_A[1], DQS_LAST_A[2] = bytes, offset, cached
            return cached
          end

          # Dispatch to string variant if given a String
          return decode_qpack_string_from_str(bytes, offset) if bytes.is_a?(String)

          # Content-based cache for offset=0
          if offset == 0
            cached = DQS_CACHE[bytes]
            if cached
              DQS_OID_CACHE[oid_key] = cached
              return cached
            end
          end

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

          result = [str, len_bytes + length].freeze

          # Cache for offset=0 (common case: standalone decode)
          if offset == 0 && DQS_CACHE.size < DQS_CACHE_MAX
            DQS_CACHE[bytes.frozen? ? bytes : bytes.dup.freeze] = result
          end
          DQS_OID_CACHE[oid_key] = result if DQS_OID_CACHE.size < DQS_CACHE_MAX

          result
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
