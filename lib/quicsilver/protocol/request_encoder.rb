# frozen_string_literal: true

module Quicsilver
  module Protocol
    class RequestEncoder
      def initialize(method:, path:, scheme: "https", authority: "localhost:4433", headers: {}, body: nil, priority: nil, encoder: Qpack::Encoder.new)
        @priority = priority
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
        headers = [[":method", @method]]
        if @method == "CONNECT"
          headers << [":authority", @authority]
        else
          headers << [":scheme", @scheme]
          headers << [":authority", @authority]
          headers << [":path", @path]
        end
        pairs = headers + @headers.map { |k, v| [k.to_s, v.to_s] }
        pairs << ["priority", @priority.to_s] if @priority
        pairs
      end

      def build_frame(type, payload)
        Protocol.encode_varint(type) + Protocol.encode_varint(payload.bytesize) + payload
      end
    end
  end
end
