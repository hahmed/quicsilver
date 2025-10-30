# frozen_string_literal: true

require 'stringio'

module Quicsilver
  module HTTP3
    class RequestParser
      attr_reader :frames, :headers, :body

      def initialize(data)
        @data = data
        @frames = []
        @headers = {}
        @body = StringIO.new
      end

      def parse
        parse!
      end

      def to_rack_env(stream_info = {})
        return nil if @headers.empty?

        # Extract path and query string
        path_full = @headers[':path'] || '/'
        path, query = path_full.split('?', 2)

        # Extract host and port
        authority = @headers[':authority'] || 'localhost:4433'
        host, port = authority.split(':', 2)
        port ||= '4433'

        env = {
          'REQUEST_METHOD' => @headers[':method'] || 'GET',
          'PATH_INFO' => path,
          'QUERY_STRING' => query || '',
          'SERVER_NAME' => host,
          'SERVER_PORT' => port,
          'SERVER_PROTOCOL' => 'HTTP/3',
          'rack.version' => [1, 3],
          'rack.url_scheme' => @headers[':scheme'] || 'https',
          'rack.input' => @body,
          'rack.errors' => $stderr,
          'rack.multithread' => true,
          'rack.multiprocess' => false,
          'rack.run_once' => false,
          'rack.hijack?' => false,
          'SCRIPT_NAME' => '',
          'CONTENT_LENGTH' => @body.size.to_s,
        }

        # Add regular headers as HTTP_*
        @headers.each do |name, value|
          next if name.start_with?(':')
          env["HTTP_#{name.upcase.tr('-', '_')}"] = value
        end

        env
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
            @body.write(payload)
          end

          offset += header_len + length
        end

        @body.rewind
      end

      def parse_headers(payload)
        # Skip QPACK required insert count (1 byte) + delta base (1 byte)
        offset = 2
        return if payload.bytesize < offset

        while offset < payload.bytesize
          byte = payload.bytes[offset]

          # Indexed field line (static table, starts with 0x4X or 0x5X)
          if (byte & 0xC0) == 0x40 || (byte & 0xC0) == 0x80
            index = byte & 0x3F
            offset += 1

            # Check if this is a complete field (name+value) or just name
            field = decode_static_table_field(index)

            if field.is_a?(Hash)
              # Complete field with both name and value (e.g., :method GET)
              @headers.merge!(field)
            elsif field
              # Name-only entry, value follows
              value_len, len_bytes = HTTP3.decode_varint(payload.bytes, offset)
              offset += len_bytes
              value = payload[offset, value_len]
              offset += value_len
              @headers[field] = value
            end
          # Literal with literal name (starts with 0x2X)
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
            break # Unknown encoding
          end
        end
      end

      # QPACK static table decoder (RFC 9204 Appendix A)
      # Returns Hash for complete fields, String for name-only fields
      def decode_static_table_field(index)
        case index
        when HTTP3::QPACK_AUTHORITY then ':authority'
        when HTTP3::QPACK_PATH then ':path'
        when HTTP3::QPACK_METHOD_CONNECT then {':method' => 'CONNECT'}
        when HTTP3::QPACK_METHOD_DELETE then {':method' => 'DELETE'}
        when HTTP3::QPACK_METHOD_GET then {':method' => 'GET'}
        when HTTP3::QPACK_METHOD_HEAD then {':method' => 'HEAD'}
        when HTTP3::QPACK_METHOD_OPTIONS then {':method' => 'OPTIONS'}
        when HTTP3::QPACK_METHOD_POST then {':method' => 'POST'}
        when HTTP3::QPACK_METHOD_PUT then {':method' => 'PUT'}
        when HTTP3::QPACK_SCHEME_HTTP then {':scheme' => 'http'}
        when HTTP3::QPACK_SCHEME_HTTPS then {':scheme' => 'https'}
        else nil
        end
      end
    end
  end
end
