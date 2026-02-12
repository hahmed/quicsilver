# frozen_string_literal: true
require_relative "huffman_code"

module Quicsilver
  module Qpack
    class Encoder
      STATIC_TABLE = HTTP3::STATIC_TABLE

      def initialize(huffman: true)
        @huffman = huffman
      end

      def encode(headers)
        out = encode_prefix
        headers.each { |name, value| out << encode_field(name, value) }
        out
      end

      def lookup(name, value)
        lookup_static(name, value)
      end

      def encode_prefix
        "\x00\x00".b # Required Insert Count = 0, Base = 0
      end

      private

      # Returns [index, full_match] or nil
      def lookup_static(name, value)
        name = name.to_s.downcase
        value = value.to_s

        name_only_index = nil

        STATIC_TABLE.each_with_index do |(tbl_name, tbl_value), idx|
          next unless tbl_name == name

          name_only_index ||= idx
          return [idx, true] if tbl_value == value
        end

        name_only_index ? [name_only_index, false] : nil
      end

      def encode_field(name, value)
        name = name.to_s.downcase
        value = value.to_s

        case lookup(name, value)
        in [index, true]
          encode_indexed(index)
        in [index, false] if index < 64
          encode_literal_with_name_ref(index, value)
        else
          encode_literal(name, value)
        end
      end

      # Pattern 1: Indexed Field Line (1xxxxxxx)
      def encode_indexed(index)
        encode_prefixed_int(index, 6, 0xC0)
      end

      # Pattern 3: Literal with Name Reference (01xxxxxx)
      def encode_literal_with_name_ref(index, value)
        out = [0x40 | index].pack("C")
        out << encode_str(value)
        out
      end

      # Pattern 5: Literal with Literal Name (001xxxxx)
      def encode_literal(name, value)
        name_str = name.to_s.b
        if @huffman
          huffman_name = HuffmanCode.encode(name_str)
          if huffman_name.bytesize < name_str.bytesize
            out = encode_prefixed_int(huffman_name.bytesize, 3, 0x28) # 001 H=1 xxx
            out << huffman_name
            out << encode_str(value)
            return out
          end
        end
        out = encode_prefixed_int(name_str.bytesize, 3, 0x20) # 001 H=0 xxx
        out << name_str
        out << encode_str(value)
        out
      end

      def encode_str(value)
        value = value.to_s.b
        if @huffman
          huffman = HuffmanCode.encode(value)
          if huffman.bytesize < value.bytesize
            return encode_prefixed_int(huffman.bytesize, 7, 0x80) + huffman # H=1
          end
        end
        encode_prefixed_int(value.bytesize, 7, 0x00) + value # H=0
      end

      # RFC 7541 prefix integer encoding
      def encode_prefixed_int(value, prefix_bits, pattern)
        max_prefix = (1 << prefix_bits) - 1

        if value < max_prefix
          [pattern | value].pack('C')
        else
          out = [pattern | max_prefix].pack('C')
          value -= max_prefix
          while value >= 128
            out << [(value & 0x7F) | 0x80].pack('C')
            value >>= 7
          end
          out << [value].pack('C')
          out
        end
      end
    end
  end
end
