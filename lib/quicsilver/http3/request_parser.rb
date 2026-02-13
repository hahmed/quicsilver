# frozen_string_literal: true

require "stringio"
require_relative "../qpack/decoder"

module Quicsilver
  module HTTP3
    class RequestParser
      include Qpack::Decoder
      attr_reader :frames, :headers, :body

      def initialize(data)
        @data = data
        @frames = []
        @headers = {}
        @body = StringIO.new
        @body.set_encoding(Encoding::ASCII_8BIT)
      end

      def parse
        parse!
      end

      def to_rack_env(stream_info = {})
        return nil if @headers.empty?
        return nil unless @headers[":method"] && @headers[":scheme"] && @headers[":path"]

        path_full = @headers[":path"]
        path, query = path_full.split("?", 2)

        authority = @headers[":authority"] || "localhost:4433"
        host, port = authority.split(":", 2)
        port ||= "4433"

        env = {
          "REQUEST_METHOD" => @headers[":method"],
          "PATH_INFO" => path,
          "QUERY_STRING" => query || "",
          "SERVER_NAME" => host,
          "SERVER_PORT" => port,
          "SERVER_PROTOCOL" => "HTTP/3",
          "rack.version" => [1, 3],
          "rack.url_scheme" => @headers[":scheme"] || "https",
          "rack.input" => @body,
          "rack.errors" => $stderr,
          "rack.multithread" => true,
          "rack.multiprocess" => false,
          "rack.run_once" => false,
          "rack.hijack?" => false,
          "SCRIPT_NAME" => "",
          "CONTENT_LENGTH" => @body.size.to_s,
        }

        if @headers[":authority"]
          env["HTTP_HOST"] = @headers[":authority"]
        end

        @headers.each do |name, value|
          next if name.start_with?(":")
          key = name.upcase.tr("-", "_")
          if key == "CONTENT_TYPE"
            env["CONTENT_TYPE"] = value
          elsif key == "CONTENT_LENGTH"
            env["CONTENT_LENGTH"] = value
          else
            env["HTTP_#{key}"] = value
          end
        end

        env
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
            @body.write(payload)
          end

          offset += header_len + length
        end

        @body.rewind
      end

      # QPACK header block decoding (RFC 9204 §4.5)
      # Skips 2-byte prefix (required insert count + delta base), then decodes
      # field lines using one of three patterns identified by high bits.
      def parse_headers(payload)
        offset = 2
        return if payload.bytesize < offset

        while offset < payload.bytesize
          byte = payload.bytes[offset]

          # Indexed Field Line (1Txxxxxx) — name + value from static table
          if (byte & 0x80) == 0x80
            index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 6, 0xC0)
            offset += bytes_consumed

            field = decode_static_table_field(index)
            if field.is_a?(Hash)
              @headers.merge!(field)
            end
          # Literal with Name Reference (01NTxxxx) — name from static table, literal value
          elsif (byte & 0xC0) == 0x40
            index, bytes_consumed = decode_prefix_integer(payload.bytes, offset, 4, 0xF0)
            offset += bytes_consumed

            entry = HTTP3::STATIC_TABLE[index] if index < HTTP3::STATIC_TABLE.size
            name = entry ? entry[0] : nil

            if name
              value, consumed = decode_qpack_string(payload.bytes, offset)
              offset += consumed
              @headers[name] = value
            end
          # Literal with Literal Name (001NHxxx) — both name and value are literals
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
