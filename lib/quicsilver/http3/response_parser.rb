# frozen_string_literal: true

require 'stringio'

module Quicsilver
  module HTTP3
    class ResponseParser
      attr_reader :frames, :headers, :status

      def initialize(data)
        @data = data
        @frames = []
        @headers = {}
        @body_io = StringIO.new
        @status = nil
      end

      def body
        @body_io.rewind
        @body_io
      end

      def parse
        parse!
      end

      private

      def parse!
        buffer = @data.dup
        offset = 0

        while offset < buffer.bytesize
          break if buffer.bytesize - offset < 2

          type, type_len = HTTP3.decode_varint(buffer.bytes, offset)
          length, length_len = HTTP3.decode_varint(buffer.bytes, offset + type_len)
          header_len = type_len + length_len

          break if buffer.bytesize < offset + header_len + length

          payload = buffer[offset + header_len, length]
          @frames << { type: type, length: length, payload: payload }

          case type
          when 0x01 # HEADERS
            parse_headers(payload)
          when 0x00 # DATA
            @body_io.write(payload)
          end

          offset += header_len + length
        end
      end

      def parse_headers(payload)
        # Skip QPACK required insert count (1 byte) + delta base (1 byte)
        offset = 2
        return if payload.bytesize < offset

        while offset < payload.bytesize
          byte = payload.bytes[offset]

          # Pattern 1: Indexed Field Line (1Txxxxxx)
          if (byte & 0x80) == 0x80
            # Decode prefix integer with N=6 bits
            index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 6, 0xC0)
            offset += bytes_consumed

            field = decode_static_table_field(index)
            if field.is_a?(Hash)
              field.each do |name, value|
                if name == ":status"
                  @status = value.to_i
                else
                  @headers[name] = value
                end
              end
            end
          # Pattern 3: Literal with Name Reference (01NTxxxx)
          elsif (byte & 0xC0) == 0x40
            index = byte & 0x3F
            offset += 1

            entry = HTTP3::STATIC_TABLE[index] if index < HTTP3::STATIC_TABLE.size
            name = entry ? entry[0] : nil

            if name
              value_len, len_bytes = HTTP3.decode_varint(payload.bytes, offset)
              offset += len_bytes
              value = payload[offset, value_len]
              offset += value_len

              if name == ":status"
                @status = value.to_i
              else
                @headers[name] = value
              end
            end
          # Pattern 5: Literal with literal name (001NHxxx)
          elsif (byte & 0xE0) == 0x20
            name_len = byte & 0x1F
            offset += 1
            name = payload[offset, name_len]
            offset += name_len

            value_len, len_bytes = HTTP3.decode_varint(payload.bytes, offset)
            offset += len_bytes
            value = payload[offset, value_len]
            offset += value_len

            @headers[name] = value
          else
            break
          end
        end
      end

      def decode_static_table_field(index)
        return nil if index >= HTTP3::STATIC_TABLE.size

        name, value = HTTP3::STATIC_TABLE[index]

        if value.empty?
          name
        else
          {name => value}
        end
      end

      # Decode prefix integer (RFC 7541)
      # Returns [value, bytes_consumed]
      def decode_prefix_integer(bytes, offset, prefix_bits, pattern_mask)
        max_prefix = (1 << prefix_bits) - 1  # 2^N - 1

        first_byte = bytes[offset]
        value = first_byte & max_prefix
        bytes_consumed = 1

        # If all prefix bits are 1, value continues in next byte(s)
        if value == max_prefix
          multiplier = 1
          loop do
            return [value, bytes_consumed] if offset + bytes_consumed >= bytes.size

            next_byte = bytes[offset + bytes_consumed]
            bytes_consumed += 1

            value += (next_byte & 0x7F) * multiplier
            break if (next_byte & 0x80) == 0  # MSB=0 means last byte

            multiplier *= 128
          end
        end

        [value, bytes_consumed]
      end
    end
  end
end
