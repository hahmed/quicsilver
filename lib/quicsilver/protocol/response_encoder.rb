# frozen_string_literal: true

module Quicsilver
  module Protocol
    class ResponseEncoder
      # Encode an informational (1xx) response as a single HEADERS frame.
      # RFC 9114 §4.1: informational responses are encoded as HEADERS with no body.
      def self.encode_informational(status, headers, encoder: Qpack::Encoder.new)
        raise ArgumentError, "Informational status must be 1xx, got #{status}" unless (100..199).include?(status)

        pairs = [[":status", status.to_s]]
        headers.each { |name, value| pairs << [name.to_s.downcase, value.to_s] }
        encoded = encoder.encode(pairs)

        Protocol.encode_varint(FRAME_HEADERS) +
          Protocol.encode_varint(encoded.bytesize) +
          encoded
      end

      def initialize(status, headers, body, encoder: Qpack::Encoder.new, head_request: false, trailers: nil)
        @status = status
        @headers = headers
        @body = body
        @encoder = encoder
        @head_request = head_request
        @trailers = trailers
      end

      # Buffered encode - returns all frames at once
      def encode
        frames = "".b
        frames << build_frame(FRAME_HEADERS, @encoder.encode(all_headers))
        unless @head_request
          @body.each do |chunk|
            frames << build_frame(FRAME_DATA, chunk) unless chunk.empty?
          end
        end
        frames << build_frame(FRAME_HEADERS, @encoder.encode(trailer_headers)) if @trailers&.any?
        @body.close if @body.respond_to?(:close)
        frames
      end

      # Streaming encode - yields frames as they're ready
      def stream_encode
        yield build_frame(FRAME_HEADERS, @encoder.encode(all_headers)), false

        unless @head_request
          last_chunk = nil
          @body.each do |chunk|
            yield build_frame(FRAME_DATA, last_chunk), false if last_chunk && !last_chunk.empty?
            last_chunk = chunk
          end

          if @trailers&.any?
            yield build_frame(FRAME_DATA, last_chunk), false if last_chunk && !last_chunk.empty?
            yield build_frame(FRAME_HEADERS, @encoder.encode(trailer_headers)), true
          elsif last_chunk && !last_chunk.empty?
            yield build_frame(FRAME_DATA, last_chunk), true
          else
            yield "".b, true
          end
        else
          yield "".b, true
        end

        @body.close if @body.respond_to?(:close)
      end

      private

      # RFC 9114 §4.2: connection-specific header fields must not appear in HTTP/3
      FORBIDDEN_HEADERS = %w[transfer-encoding connection keep-alive upgrade te proxy-connection].freeze

      def all_headers
        headers = [[":status", @status.to_s]]
        @headers.each do |name, value|
          downcased = name.to_s.downcase
          next if downcased.start_with?("rack.")
          next if FORBIDDEN_HEADERS.include?(downcased)
          headers << [downcased, value.to_s]
        end
        headers
      end

      def trailer_headers
        @trailers.map { |name, value| [name.to_s.downcase, value.to_s] }
      end

      def build_frame(type, payload)
        payload = payload.to_s.b
        Protocol.encode_varint(type) + Protocol.encode_varint(payload.bytesize) + payload
      end


    end
  end
end
