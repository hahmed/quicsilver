# frozen_string_literal: true

require 'stringio'

module Quicsilver
  module HTTP3
    class RequestParser
      attr_reader :frames, :headers, :body

      def initialize(data, codec:)
        @data = data
        @codec = codec
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

        path_full = @headers[':path'] || '/'
        path, query = path_full.split('?', 2)

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

        if @headers[':authority']
          env['HTTP_HOST'] = @headers[':authority']
        end

        @headers.each do |name, value|
          next if name.start_with?(':')
          key = name.upcase.tr('-', '_')
          if key == 'CONTENT_TYPE'
            env['CONTENT_TYPE'] = value
          elsif key == 'CONTENT_LENGTH'
            env['CONTENT_LENGTH'] = value
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
            @headers = @codec.decode_headers(payload)
          when 0x00 # DATA
            @body.write(payload)
          end

          offset += header_len + length
        end

        @body.rewind
      end
    end
  end
end
