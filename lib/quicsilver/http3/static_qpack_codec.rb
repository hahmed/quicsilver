# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class StaticQPACKCodec
      def initialize(connection = nil)
        @connection = connection
      end

      def encode_headers(headers)
        encoded = "\x00\x00".b

        headers.each do |name, value|
          next if name.to_s.start_with?('rack.')

          name = name.to_s.downcase
          value = value.to_s

          index = find_static_index(name, value)
          if index
            encoded << encode_indexed_field(index)
          else
            name_index = find_static_name_index(name)
            if name_index
              encoded << encode_literal_with_name_ref(name_index, value)
            else
              encoded << encode_literal_with_literal_name(name, value)
            end
          end
        end

        encoded
      end

      def decode_headers(payload)
        headers = {}
        offset = 2

        return headers if payload.bytesize < offset

        while offset < payload.bytesize
          byte = payload.bytes[offset]

          if (byte & 0x80) == 0x80
            index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 6, 0xC0)
            offset += bytes_consumed

            if index < STATIC_TABLE.size
              name, value = STATIC_TABLE[index]
              headers[name] = value unless value.empty?
            end

          elsif (byte & 0xC0) == 0x40
            index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 4, 0x40)
            offset += bytes_consumed

            if index < STATIC_TABLE.size
              name = STATIC_TABLE[index][0]
              value_len, len_bytes = HTTP3.decode_varint(payload.bytes, offset)
              offset += len_bytes
              value = payload[offset, value_len]
              offset += value_len
              headers[name] = value
            end

          elsif (byte & 0xE0) == 0x20
            name_len = byte & 0x1F
            offset += 1
            name = payload[offset, name_len]
            offset += name_len

            value_len, len_bytes = HTTP3.decode_varint(payload.bytes, offset)
            offset += len_bytes
            value = payload[offset, value_len]
            offset += value_len

            headers[name] = value
          else
            break
          end
        end

        headers
      end

      private

      def find_static_index(name, value)
        STATIC_TABLE.each_with_index do |(tbl_name, tbl_value), idx|
          return idx if tbl_name == name && tbl_value == value
        end
        nil
      end

      def find_static_name_index(name)
        STATIC_TABLE.each_with_index do |(tbl_name, _), idx|
          return idx if tbl_name == name
        end
        nil
      end

      def encode_indexed_field(index)
        encode_prefix_integer(index, prefix_bits: 6, pattern: 0x80)
      end

      def encode_literal_with_name_ref(name_index, value)
        result = encode_prefix_integer(name_index, prefix_bits: 4, pattern: 0x40)
        value_bytes = value.to_s.b
        result + HTTP3.encode_varint(value_bytes.bytesize) + value_bytes
      end

      def encode_literal_with_literal_name(name, value)
        name_bytes = name.to_s.b
        value_bytes = value.to_s.b
        prefix = [0x20 | name_bytes.bytesize].pack('C')
        prefix + name_bytes + HTTP3.encode_varint(value_bytes.bytesize) + value_bytes
      end

      def encode_prefix_integer(value, prefix_bits:, pattern:)
        max_prefix = (1 << prefix_bits) - 1

        if value < max_prefix
          [pattern | value].pack('C')
        else
          result = [pattern | max_prefix].pack('C')
          remaining = value - max_prefix

          while remaining >= 128
            result << [(remaining & 0x7F) | 0x80].pack('C')
            remaining >>= 7
          end
          result << [remaining].pack('C')

          result
        end
      end

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
