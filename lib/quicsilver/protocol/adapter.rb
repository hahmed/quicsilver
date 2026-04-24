# frozen_string_literal: true

require "protocol/http/request"
require "protocol/http/response"
require "protocol/http/headers"
require_relative "stream_input"
require_relative "stream_output"

module Quicsilver
  module Protocol
    # Converts between QUIC/HTTP/3 frames and protocol-http Request/Response
    # objects. This enables integration with Falcon and any other server
    # built on protocol-http.
    #
    # Usage:
    #   adapter = Protocol::Adapter.new(app)
    #   request, body = adapter.build_request(parsed_headers)
    #   body.write(chunk)               # feed body data
    #   body.close_write                # signal end of body
    #   response = adapter.call(request)
    #   adapter.send_response(response, writer)
    #
    class Adapter
      VERSION = "HTTP/3"

      def initialize(app)
        @app = app
        @qpack_encoder = Quicsilver::Protocol::Qpack::Encoder.new
      end

      # Build a Protocol::HTTP::Request from parsed HTTP/3 headers.
      #
      # Returns [request, body] where body is a Protocol::StreamInput that
      # the transport feeds RECEIVE chunks into.
      #
      # @param headers [Hash] Parsed headers from RequestParser (includes pseudo-headers).
      # @return [Array(Protocol::HTTP::Request, Protocol::StreamInput)] request and body.
      #   Body is nil for bodyless methods (GET, HEAD, TRACE).
      #   Caller feeds RECEIVE data into body via write(), then close_write on FIN.
      def build_request(headers)
        method = headers[":method"]
        scheme = headers[":scheme"] || "https"
        authority = headers[":authority"]
        path = headers[":path"]
        protocol = headers[":protocol"]
        content_length = headers["content-length"]&.to_i

        protocol_headers = ::Protocol::HTTP::Headers.new
        headers.each do |name, value|
          next if name.start_with?(":")
          protocol_headers.add(name, value)
        end

        body = unless bodyless_request?(method)
          Protocol::StreamInput.new(content_length)
        end

        request = ::Protocol::HTTP::Request.new(
          scheme, authority, method, path, VERSION,
          protocol_headers, body, protocol
        )

        [request, body]
      end

      # Send a Protocol::HTTP::Response via a transport writer.
      #
      # Encodes the response headers as an HTTP/3 HEADERS frame, then streams
      # the response body as DATA frames via Protocol::StreamOutput.
      #
      # @param response [Protocol::HTTP::Response] The response to send.
      # @param writer [#call] Transport writer — accepts (data, fin) for sending bytes.
      # @param head_request [Boolean] Whether this was a HEAD request.
      # @return [void]
      def send_response(response, writer, head_request: false)
        status = response.status
        headers = response.headers
        trailers = extract_trailers(headers)
        headers_hash = response_headers_hash(headers)
        body = response.body

        if body.nil? || head_request
          send_headers_only(status, headers_hash, writer, trailers: trailers)
        elsif body.respond_to?(:read)
          stream_response(status, headers_hash, body, writer, trailers: trailers)
        else
          buffer_response(status, headers_hash, body, writer, trailers: trailers)
        end
      end

      # Call the protocol-http application with the request.
      #
      # @param request [Protocol::HTTP::Request]
      # @return [Protocol::HTTP::Response]
      def call(request)
        @app.call(request)
      end

      private

      # Methods where a body has no defined semantics (RFC 9110 §9.3.1, §9.3.2, §9.3.8).
      # GET and HEAD SHOULD NOT have a body. TRACE MUST NOT.
      # DELETE, OPTIONS, CONNECT can all have meaningful bodies.
      BODYLESS_METHODS = %w[GET HEAD TRACE].freeze

      def bodyless_request?(method)
        BODYLESS_METHODS.include?(method)
      end

      # No body — send HEADERS with FIN
      def send_headers_only(status, headers, writer, trailers: nil)
        encoder = Quicsilver::Protocol::ResponseEncoder.new(status, headers, [], trailers: trailers)
        writer.call(encoder.encode, true)
      end

      # Streaming body (protocol-http Body::Readable) — send HEADERS, then
      # stream DATA frames as chunks arrive. Used by Falcon mode.
      def stream_response(status, headers, body, writer, trailers: nil)
        has_trailers = trailers&.any?
        writer.call(build_headers_frame(status, headers), false)
        Protocol::StreamOutput.new(body, &writer).stream(send_fin: !has_trailers)
        writer.call(build_trailer_frame(trailers), true) if has_trailers
      end

      # Buffered body (Rack array or enumerable) — encode everything and send.
      def buffer_response(status, headers, body, writer, trailers: nil)
        parts = body.respond_to?(:each) ? body : [body.to_s]
        encoder = Quicsilver::Protocol::ResponseEncoder.new(status, headers, parts, trailers: trailers)
        writer.call(encoder.encode, true)
      ensure
        body.close if body.respond_to?(:close)
      end

      # Extract trailers from Protocol::HTTP::Headers if present.
      # Returns a Hash or nil.
      def extract_trailers(headers)
        return nil unless headers.respond_to?(:trailer?) && headers.trailer?

        result = {}
        headers.trailer.each do |name, value|
          result[name] = value
        end
        result
      end

      # Convert Protocol::HTTP::Headers to a plain Hash for ResponseEncoder.
      # Only includes headers, not trailers.
      def response_headers_hash(headers)
        return {} unless headers

        headers.header.to_h
      end

      # Build an HTTP/3 HEADERS frame from key-value pairs
      def build_qpack_frame(pairs)
        encoded = @qpack_encoder.encode(pairs)
        Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::FRAME_HEADERS) +
          Quicsilver::Protocol.encode_varint(encoded.bytesize) +
          encoded
      end

      # Build a response HEADERS frame (with :status pseudo-header)
      def build_headers_frame(status, headers)
        pairs = [[":status", status.to_s]]
        headers.each { |name, value| pairs << [name.to_s.downcase, value.to_s] }
        build_qpack_frame(pairs)
      end

      # Build a trailer HEADERS frame
      def build_trailer_frame(trailers)
        pairs = trailers.map { |name, value| [name.to_s.downcase, value.to_s] }
        build_qpack_frame(pairs)
      end
    end
  end
end
