# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class RequestEncoder
      def initialize(method:, path:, scheme: "https", authority: "localhost:4433", headers: {}, body: nil, encoder: Qpack::Encoder.new)
        @method = method.upcase
        @path = path
        @scheme = scheme
        @authority = authority
        @headers = headers
        @body = body
        @encoder = encoder
      end

      def encode
        frames = "".b
        frames << build_frame(FRAME_HEADERS, @encoder.encode(all_headers))

        if @body && !@body.empty?
          body_data = @body.is_a?(String) ? @body : @body.join
          frames << build_frame(FRAME_DATA, body_data)
        end

        frames
      end

      private

      def all_headers
        [
          [":method", @method],
          [":scheme", @scheme],
          [":authority", @authority],
          [":path", @path]
        ] + @headers.map { |k, v| [k.to_s, v.to_s] }
      end

      def build_frame(type, payload)
        HTTP3.encode_varint(type) + HTTP3.encode_varint(payload.bytesize) + payload
      end
    end
  end
end
