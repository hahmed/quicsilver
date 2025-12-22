# frozen_string_literal: true

require 'stringio'

module Quicsilver
  module HTTP3
    class ResponseParser
      attr_reader :frames, :headers, :status

      def initialize(data, codec:)
        @data = data
        @codec = codec
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
            decoded = @codec.decode_headers(payload)
            @status = decoded.delete(':status')&.to_i
            @headers = decoded
          when 0x00 # DATA
            @body_io.write(payload)
          end

          offset += header_len + length
        end
      end
    end
  end
end
