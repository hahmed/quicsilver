# frozen_string_literal: true

require "stringio"
require_relative "../qpack/decoder"

module Quicsilver
  module HTTP3
    class ResponseParser
      include Qpack::Decoder
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
        headers_received = false

        while offset < buffer.bytesize
          break if buffer.bytesize - offset < 2

          type, type_len = HTTP3.decode_varint(buffer.bytes, offset)
          length, length_len = HTTP3.decode_varint(buffer.bytes, offset + type_len)
          break if type_len == 0 || length_len == 0

          header_len = type_len + length_len

          break if buffer.bytesize < offset + header_len + length

          payload = buffer[offset + header_len, length]
          @frames << { type: type, length: length, payload: payload }

          if HTTP3::CONTROL_ONLY_FRAMES.include?(type)
            raise HTTP3::FrameError, "Frame type 0x#{type.to_s(16)} not allowed on request streams"
          end

          case type
          when 0x01 # HEADERS
            parse_headers(payload)
            headers_received = true
          when 0x00 # DATA
            raise HTTP3::FrameError, "DATA frame before HEADERS" unless headers_received
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
          # Bits: 01=pattern, N=never-index, T=table(1=static), xxxx=4-bit prefix index
          elsif (byte & 0xC0) == 0x40
            index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 4, 0xF0)
            offset += bytes_consumed

            entry = HTTP3::STATIC_TABLE[index] if index < HTTP3::STATIC_TABLE.size
            name = entry ? entry[0] : nil

            if name
              value, consumed = decode_qpack_string(payload.bytes, offset)
              offset += consumed

              if name == ":status"
                @status = value.to_i
              else
                @headers[name] = value
              end
            end
          # Pattern 5: Literal with literal name (001NHxxx)
          elsif (byte & 0xE0) == 0x20
            huffman_name = (byte & 0x08) != 0
            name_len, name_len_bytes = decode_prefix_integer(payload.bytes, offset, 3, 0x28)
            offset += name_len_bytes
            raw_name = payload[offset, name_len]
            name = if huffman_name
              Qpack::HuffmanCode.decode(raw_name) || raw_name
            else
              raw_name
            end
            offset += name_len

            value, consumed = decode_qpack_string(payload.bytes, offset)
            offset += consumed

            @headers[name] = value
          else
            break
          end
        end
      end

      def decode_static_table_field(index)
        return nil if index >= HTTP3::STATIC_TABLE.size

        name, value = HTTP3::STATIC_TABLE[index]
        {name => value}
      end
    end
  end
end
