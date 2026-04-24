# frozen_string_literal: true
require_relative "huffman"

module Quicsilver
  module Protocol
    module Qpack
      class Encoder
        STATIC_TABLE = Protocol::STATIC_TABLE

        # Pre-built hash for O(1) static table lookups
        STATIC_LOOKUP_FULL = {} # "name\0value" => index
        STATIC_LOOKUP_NAME = {} # name => first_index

        STATIC_TABLE.each_with_index do |(tbl_name, tbl_value), idx|
          STATIC_LOOKUP_FULL["#{tbl_name}\0#{tbl_value}".freeze] = idx
          STATIC_LOOKUP_NAME[tbl_name] ||= idx
        end
        STATIC_LOOKUP_FULL.freeze
        STATIC_LOOKUP_NAME.freeze

        PREFIX = "\x00\x00".b.freeze

        FIELD_CACHE_MAX = 512

        def initialize(huffman: true)
          @huffman = huffman
          @field_cache = {}
          @block_cache = {}
          @oid_cache = {}
        end

        def encode(headers)
          # Fastest path: exact same object as last call
          return @last_result if headers.equal?(@last_headers)

          # Fast path: check object_id cache (same array object reused)
          oid = headers.object_id
          cached = @oid_cache[oid]
          if cached
            @last_headers = headers
            @last_result = cached
            return cached
          end

          if headers.is_a?(Array) && headers.size <= 16
            # Content-based caching for small header sets
            block_key = headers.map { |n, v| "#{n}\0#{v}" }.join("\x01")
            cached_block = @block_cache[block_key]
            if cached_block
              @oid_cache[oid] = cached_block if @oid_cache.size < BLOCK_CACHE_MAX
              return cached_block
            end

            result = encode_fields(headers)
            result_frozen = result.freeze
            if @block_cache.size < BLOCK_CACHE_MAX
              @block_cache[block_key.freeze] = result_frozen
            end
            @oid_cache[oid] = result_frozen if @oid_cache.size < BLOCK_CACHE_MAX
            return result_frozen
          end

          encode_fields(headers)
        end

        BLOCK_CACHE_MAX = 128

        private def encode_fields(headers)
          out = encode_prefix
          headers.each do |name, value|
            name = name.to_s
            value = value.to_s
            # Downcase only if needed (most HTTP/3 headers are already lowercase)
            name = name.downcase if name.match?(/[A-Z]/)

            cache_key = "#{name}\0#{value}"

            # Check field cache
            cached = @field_cache[cache_key]
            if cached
              out << cached
              next
            end

            field_start = out.bytesize

            full_idx = STATIC_LOOKUP_FULL[cache_key]

            if full_idx
              # Indexed Field Line
              out << encode_prefixed_int(full_idx, 6, 0xC0)
            else
              name_idx = STATIC_LOOKUP_NAME[name]
              if name_idx
                # Literal with Name Reference
                out << encode_prefixed_int(name_idx, 4, 0x50)
                encode_str_into(out, value)
              else
                # Literal with Literal Name
                encode_literal_into(out, name, value)
              end
            end

            # Cache the encoded field bytes
            if @field_cache.size < FIELD_CACHE_MAX
              @field_cache[cache_key.freeze] = out.byteslice(field_start..).freeze
            end
          end
          out
        end

        def lookup(name, value)
          name = name.to_s.downcase
          value = value.to_s
          full_idx = STATIC_LOOKUP_FULL["#{name}\0#{value}"]
          return [full_idx, true] if full_idx
          name_idx = STATIC_LOOKUP_NAME[name]
          name_idx ? [name_idx, false] : nil
        end

        def encode_prefix
          PREFIX.dup
        end

        # Public API for encoding a single string value (used by tests/external code)
        def encode_str(value)
          out = "".b
          encode_str_into(out, value.to_s)
          out
        end

        private

        # Pattern 1: Indexed Field Line (1xxxxxxx) — kept for test compatibility
        def encode_indexed(index)
          encode_prefixed_int(index, 6, 0xC0)
        end

        def encode_literal_into(out, name, value)
          name_b = name.b
          if @huffman
            huffman_name = Huffman.encode(name_b)
            if huffman_name.bytesize < name_b.bytesize
              out << encode_prefixed_int(huffman_name.bytesize, 3, 0x28)
              out << huffman_name
              encode_str_into(out, value)
              return
            end
          end
          out << encode_prefixed_int(name_b.bytesize, 3, 0x20)
          out << name_b
          encode_str_into(out, value)
        end

        def encode_str_into(out, value)
          value_b = value.b
          if @huffman
            huffman = Huffman.encode(value_b)
            if huffman.bytesize < value_b.bytesize
              out << encode_prefixed_int(huffman.bytesize, 7, 0x80)
              out << huffman
              return
            end
          end
          out << encode_prefixed_int(value_b.bytesize, 7, 0x00)
          out << value_b
        end

        # Pre-computed prefix integer tables for hot encode paths.
        # Key: [prefix_bits, pattern] => Array of frozen encoded strings indexed by value.
        # Covers all values up to max_prefix (single-byte) and a range beyond.
        PREFIXED_INT_CACHE = {}
        [
          [6, 0xC0],  # Indexed Field Line
          [4, 0x50],  # Literal with Name Reference (static)
          [7, 0x80],  # Huffman string length
          [7, 0x00],  # Raw string length
          [3, 0x28],  # Huffman literal name length
          [3, 0x20],  # Raw literal name length
        ].each do |prefix_bits, pattern|
          max_prefix = (1 << prefix_bits) - 1
          # Pre-compute single-byte range + a bit beyond for multi-byte
          limit = [max_prefix + 64, 256].min
          table = Array.new(limit) do |value|
            if value < max_prefix
              (pattern | value).chr(Encoding::BINARY).freeze
            else
              buf = (pattern | max_prefix).chr(Encoding::BINARY)
              v = value - max_prefix
              while v >= 128
                buf << ((v & 0x7F) | 0x80).chr(Encoding::BINARY)
                v >>= 7
              end
              buf << v.chr(Encoding::BINARY)
              buf.freeze
            end
          end
          PREFIXED_INT_CACHE[[prefix_bits, pattern]] = table.freeze
        end
        PREFIXED_INT_CACHE.freeze

        # RFC 7541 prefix integer encoding
        def encode_prefixed_int(value, prefix_bits, pattern)
          table = PREFIXED_INT_CACHE[[prefix_bits, pattern]]
          if table && value < table.size
            return table[value]
          end

          max_prefix = (1 << prefix_bits) - 1

          if value < max_prefix
            (pattern | value).chr(Encoding::BINARY)
          else
            buf = (pattern | max_prefix).chr(Encoding::BINARY)
            value -= max_prefix
            while value >= 128
              buf << ((value & 0x7F) | 0x80).chr(Encoding::BINARY)
              value >>= 7
            end
            buf << value.chr(Encoding::BINARY)
            buf
          end
        end
      end
    end
  end
end
