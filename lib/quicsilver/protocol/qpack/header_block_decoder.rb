# frozen_string_literal: true

require_relative "decoder"
require_relative "huffman"

module Quicsilver
  module Protocol
    module Qpack
      # Decodes a QPACK header block into [name, value] pairs.
      #
      # Default implementation uses the static table only (no dynamic table).
      # To add dynamic table support, implement a class with the same #decode interface:
      #
      #   class MyDynamicDecoder
      #     def decode(payload)
      #       # parse QPACK field lines from payload
      #       # yield [name, value] for each decoded header
      #     end
      #   end
      #
      # Then inject it:
      #   RequestParser.new(data, decoder: MyDynamicDecoder.new)
      #   ResponseParser.new(data, decoder: MyDynamicDecoder.new)
      #
      class HeaderBlockDecoder
        include Decoder

        DECODE_CACHE_MAX = 256

        # Shared default instance for parsers that don't need custom decoders
        def self.default
          @default ||= new
        end

        def initialize
          @decode_cache = {}
        end

        # Decode a QPACK header block payload (RFC 9204 §4.5).
        # Yields [name, value] for each decoded field line.
        def decode(payload)
          return if payload.nil? || payload.bytesize < 2

          # Check cache for previously decoded payloads
          if payload.bytesize <= 256
            cached = @decode_cache[payload]
            if cached
              cached.each { |name, value| yield name, value }
              return
            end
          end

          headers = []

          # Decode Required Insert Count (RFC 9204 §4.5.1) — 8-bit prefix integer
          required_insert_count, ric_bytes = decode_prefix_integer_str(payload, 0, 8, 0x00)
          offset = ric_bytes

          # Decode Delta Base (RFC 9204 §4.5.1) — 7-bit prefix integer with sign bit
          delta_base, db_bytes = decode_prefix_integer_str(payload, offset, 7, 0x80)
          offset += db_bytes

          # Static-only mode: Required Insert Count and Delta Base must be 0
          if required_insert_count != 0 || delta_base != 0
            raise Protocol::FrameError.new(
              "Dynamic QPACK table not supported (required_insert_count=#{required_insert_count}, delta_base=#{delta_base})",
              error_code: Protocol::QPACK_DECOMPRESSION_FAILED
            )
          end

          while offset < payload.bytesize
            byte = payload.getbyte(offset)

            # Indexed Field Line (1Txxxxxx) — name + value from static table
            if (byte & 0x80) == 0x80
              index, bytes_consumed = decode_prefix_integer_str(payload, offset, 6, 0xC0)
              offset += bytes_consumed

              if index < Protocol::STATIC_TABLE.size
                name, value = Protocol::STATIC_TABLE[index]
                headers << [name, value]
                yield name, value
              else
                raise Protocol::FrameError.new(
                  "Invalid QPACK static table index #{index}",
                  error_code: Protocol::QPACK_DECOMPRESSION_FAILED
                )
              end

            # Literal with Name Reference (01NTxxxx) — name from static table, literal value
            elsif (byte & 0xC0) == 0x40
              index, bytes_consumed = decode_prefix_integer_str(payload, offset, 4, 0xF0)
              offset += bytes_consumed

              if index >= Protocol::STATIC_TABLE.size
                raise Protocol::FrameError.new(
                  "Invalid QPACK static table index #{index}",
                  error_code: Protocol::QPACK_DECOMPRESSION_FAILED
                )
              end

              name = Protocol::STATIC_TABLE[index][0]
              value, consumed = decode_qpack_string_from_str(payload, offset)
              offset += consumed
              headers << [name, value]
              yield name, value

            # Literal with Literal Name (001NHxxx) — both name and value are literals
            elsif (byte & 0xE0) == 0x20
              huffman_name = (byte & 0x08) != 0
              name_len, name_len_bytes = decode_prefix_integer_str(payload, offset, 3, 0x28)
              offset += name_len_bytes
              raw_name = payload.byteslice(offset, name_len)
              name = if huffman_name
                Huffman.decode(raw_name) || raw_name
              else
                raw_name
              end
              offset += name_len

              value, consumed = decode_qpack_string_from_str(payload, offset)
              offset += consumed

              headers << [name, value]
              yield name, value
            else
              break
            end
          end

          # Cache the result
          if payload.bytesize <= 256 && @decode_cache.size < DECODE_CACHE_MAX
            key = payload.frozen? ? payload : payload.dup.freeze
            @decode_cache[key] = headers.freeze
          end
        end
      end
    end
  end
end
