# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class ResponseEncoder
      def initialize(status, headers, body, codec:)
        @status = status
        @headers = headers
        @body = body
        @codec = codec
      end

      def encode
        frames = "".b
        frames << encode_headers_frame
        @body.each do |chunk|
          frames << encode_data_frame(chunk) unless chunk.empty?
        end
        @body.close if @body.respond_to?(:close)
        frames
      end

      def stream_encode
        yield encode_headers_frame, false

        last_chunk = nil
        @body.each do |chunk|
          yield encode_data_frame(last_chunk), false if last_chunk && !last_chunk.empty?
          last_chunk = chunk
        end

        if last_chunk && !last_chunk.empty?
          yield encode_data_frame(last_chunk), true
        else
          yield "".b, true
        end

        @body.close if @body.respond_to?(:close)
      end

      private

      def encode_headers_frame
        all_headers = { ':status' => @status.to_s }.merge(@headers)
        payload = @codec.encode_headers(all_headers)
        frame_type = HTTP3.encode_varint(HTTP3::FRAME_HEADERS)
        frame_length = HTTP3.encode_varint(payload.bytesize)
        frame_type + frame_length + payload
      end

      def encode_data_frame(data)
        frame_type = HTTP3.encode_varint(HTTP3::FRAME_DATA)
        data_bytes = data.to_s.b
        frame_length = HTTP3.encode_varint(data_bytes.bytesize)
        frame_type + frame_length + data_bytes
      end
    end
  end
end
