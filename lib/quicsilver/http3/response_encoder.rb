# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class ResponseEncoder
      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end

      def encode
        frames = ""

        # HEADERS frame
        frames += encode_headers_frame

        # DATA frame(s)
        @body.each do |chunk|
          frames += encode_data_frame(chunk) unless chunk.empty?
        end

        @body.close if @body.respond_to?(:close)

        frames
      end

      private

      def encode_headers_frame
        payload = encode_qpack_response

        frame_type = HTTP3.encode_varint(0x01)  # HEADERS
        frame_length = HTTP3.encode_varint(payload.bytesize)

        frame_type + frame_length + payload
      end

      def encode_data_frame(data)
        frame_type = HTTP3.encode_varint(0x00)  # DATA
        frame_length = HTTP3.encode_varint(data.bytesize)

        frame_type + frame_length + data
      end

      def encode_qpack_response
        # QPACK prefix: Required Insert Count = 0, Delta Base = 0
        encoded = [0x00, 0x00].pack('C*')

        # :status pseudo-header (literal indexed)
        status_str = @status.to_s
        encoded += [0x58, status_str.bytesize].pack('C*')
        encoded += status_str

        # Regular headers (literal with literal name)
        @headers.each do |name, value|
          next if name.start_with?('rack.')  # Skip Rack internals

          name = name.to_s.downcase
          value = value.to_s

          # Literal field line with literal name (0x2X prefix)
          encoded += [0x20 | name.bytesize].pack('C')
          encoded += name
          encoded += HTTP3.encode_varint(value.bytesize)
          encoded += value
        end

        encoded
      end
    end
  end
end
