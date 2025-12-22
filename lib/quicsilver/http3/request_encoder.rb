# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class RequestEncoder
      def initialize(method:, path:, scheme: 'https', authority: 'localhost:4433', headers: {}, body: nil, codec:)
        @method = method.upcase
        @path = path
        @scheme = scheme
        @authority = authority
        @headers = headers
        @body = body
        @codec = codec
      end

      def encode
        frames = []

        headers_payload = encode_headers
        frames << build_frame(HTTP3::FRAME_HEADERS, headers_payload)

        if @body && !@body.empty?
          body_data = @body.is_a?(String) ? @body : @body.join
          frames << build_frame(HTTP3::FRAME_DATA, body_data)
        end

        frames.join.force_encoding(Encoding::BINARY)
      end

      private

      def build_frame(type, payload)
        frame_type = HTTP3.encode_varint(type)
        frame_length = HTTP3.encode_varint(payload.bytesize)
        frame_type + frame_length + payload
      end

      def encode_headers
        all_headers = {
          ':method' => @method,
          ':scheme' => @scheme,
          ':authority' => @authority,
          ':path' => @path
        }.merge(@headers)

        @codec.encode_headers(all_headers)
      end
    end
  end
end
