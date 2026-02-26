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

        # Decode a QPACK header block payload (RFC 9204 §4.5).
        # Yields [name, value] for each decoded field line.
        def decode(payload)
          return if payload.nil? || payload.bytesize < 2

          offset = 2 # skip required insert count + delta base prefix

          while offset < payload.bytesize
            byte = payload.bytes[offset]

            # Indexed Field Line (1Txxxxxx) — name + value from static table
            if (byte & 0x80) == 0x80
              index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 6, 0xC0)
              offset += bytes_consumed

              if index < Protocol::STATIC_TABLE.size
                name, value = Protocol::STATIC_TABLE[index]
                yield name, value
              end

            # Literal with Name Reference (01NTxxxx) — name from static table, literal value
            elsif (byte & 0xC0) == 0x40
              index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 4, 0xF0)
              offset += bytes_consumed

              entry = Protocol::STATIC_TABLE[index] if index < Protocol::STATIC_TABLE.size
              name = entry ? entry[0] : nil

              if name
                value, consumed = decode_qpack_string(payload.bytes, offset)
                offset += consumed
                yield name, value
              end

            # Literal with Literal Name (001NHxxx) — both name and value are literals
            elsif (byte & 0xE0) == 0x20
              huffman_name = (byte & 0x08) != 0
              name_len, name_len_bytes = decode_prefix_integer(payload.bytes, offset, 3, 0x28)
              offset += name_len_bytes
              raw_name = payload[offset, name_len]
              name = if huffman_name
                Huffman.decode(raw_name) || raw_name
              else
                raw_name
              end
              offset += name_len

              value, consumed = decode_qpack_string(payload.bytes, offset)
              offset += consumed

              yield name, value
            else
              break
            end
          end
        end
      end
    end
  end
end
