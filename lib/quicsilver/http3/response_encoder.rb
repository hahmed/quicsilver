# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class ResponseEncoder
      def initialize(status, headers, body, encoder: Qpack::Encoder.new)
        @status = status
        @headers = headers
        @body = body
        @encoder = encoder
      end

      # Buffered encode - returns all frames at once
      def encode
        frames = "".b
        frames << build_frame(FRAME_HEADERS, @encoder.encode(all_headers))
        @body.each do |chunk|
          frames << build_frame(FRAME_DATA, chunk) unless chunk.empty?
        end
        @body.close if @body.respond_to?(:close)
        frames
      end

      # Streaming encode - yields frames as they're ready
      def stream_encode
        yield build_frame(FRAME_HEADERS, @encoder.encode(all_headers)), false

        last_chunk = nil
        @body.each do |chunk|
          yield build_frame(FRAME_DATA, last_chunk), false if last_chunk && !last_chunk.empty?
          last_chunk = chunk
        end

        if last_chunk && !last_chunk.empty?
          yield build_frame(FRAME_DATA, last_chunk), true
        else
          yield "".b, true
        end

        @body.close if @body.respond_to?(:close)
      end

      private

      def all_headers
        headers = [[":status", @status.to_s]]
        @headers.each do |name, value|
          next if name.to_s.start_with?("rack.")
          headers << [name.to_s, value.to_s]
        end
        headers
      end

      def build_frame(type, payload)
        payload = payload.to_s.b
        HTTP3.encode_varint(type) + HTTP3.encode_varint(payload.bytesize) + payload
      end
    end
  end
end
