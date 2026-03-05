# frozen_string_literal: true

require "stringio"
require_relative "qpack/header_block_decoder"

module Quicsilver
  module Protocol
    class RequestParser
      attr_reader :frames, :headers, :body

      # Known HTTP/3 request pseudo-headers (RFC 9114 §4.3.1)
      VALID_PSEUDO_HEADERS = %w[:method :scheme :authority :path :protocol].freeze

      # Connection-specific headers forbidden in HTTP/3 (RFC 9114 §4.2)
      FORBIDDEN_HEADERS = %w[connection transfer-encoding keep-alive upgrade proxy-connection te].freeze

      def initialize(data, decoder: Qpack::HeaderBlockDecoder.new,
                     max_body_size: nil, max_header_size: nil,
                     max_header_count: nil, max_frame_payload_size: nil)
        @data = data
        @decoder = decoder
        @max_body_size = max_body_size
        @max_header_size = max_header_size
        @max_header_count = max_header_count
        @max_frame_payload_size = max_frame_payload_size
        @frames = []
        @headers = {}
        @body = StringIO.new
        @body.set_encoding(Encoding::ASCII_8BIT)
      end

      def parse
        parse!
      end

      # Validate pseudo-header semantics per RFC 9114 §4.3.1.
      # Call after parse to check CONNECT rules, required headers, host/:authority consistency.
      def validate_headers!
        return if @headers.empty?

        method = @headers[":method"]

        if method == "CONNECT"
          raise Protocol::MessageError, "CONNECT request must include :authority" unless @headers[":authority"]
          raise Protocol::MessageError, "CONNECT request must not include :scheme" if @headers[":scheme"]
          raise Protocol::MessageError, "CONNECT request must not include :path" if @headers[":path"]
        else
          raise Protocol::MessageError, "Request missing required pseudo-header :method" unless method
          raise Protocol::MessageError, "Request missing required pseudo-header :scheme" unless @headers[":scheme"]
          raise Protocol::MessageError, "Request missing required pseudo-header :path" unless @headers[":path"]

          # RFC 9114 §4.3.1: schemes with mandatory authority (http/https) require :authority or host
          scheme = @headers[":scheme"]
          if %w[http https].include?(scheme) && !@headers[":authority"] && !@headers["host"]
            raise Protocol::MessageError, "Request with #{scheme} scheme must include :authority or host"
          end
        end

        # Host and :authority consistency (RFC 9114 §4.3.1)
        if @headers[":authority"] && @headers["host"]
          unless @headers[":authority"] == @headers["host"]
            raise Protocol::MessageError, ":authority and host header must be consistent"
          end
        end

        # Content-length vs body size (RFC 9114 §4.1.2)
        if @headers["content-length"]
          expected = @headers["content-length"].to_i
          actual = @body.size
          unless expected == actual
            raise Protocol::MessageError, "Content-length mismatch: header=#{expected}, body=#{actual}"
          end
        end
      end

      def to_rack_env(stream_info = {})
        return nil if @headers.empty?

        method = @headers[":method"]

        if method == "CONNECT"
          return nil unless @headers[":authority"]
        else
          return nil unless method && @headers[":scheme"] && @headers[":path"]
        end

        path_full = @headers[":path"] || ""
        path, query = path_full.split("?", 2)

        authority = @headers[":authority"] || "localhost:4433"
        host, port = authority.split(":", 2)
        port ||= "4433"

        env = {
          "REQUEST_METHOD" => method,
          "PATH_INFO" => path || "",
          "QUERY_STRING" => query || "",
          "SERVER_NAME" => host,
          "SERVER_PORT" => port,
          "SERVER_PROTOCOL" => "HTTP/3",
          "rack.version" => [1, 3],
          "rack.url_scheme" => @headers[":scheme"] || "https",
          "rack.input" => @body,
          "rack.errors" => $stderr,
          "rack.multithread" => true,
          "rack.multiprocess" => false,
          "rack.run_once" => false,
          "rack.hijack?" => false,
          "SCRIPT_NAME" => "",
          "CONTENT_LENGTH" => @body.size.to_s,
        }

        if @headers[":authority"]
          env["HTTP_HOST"] = @headers[":authority"]
        end

        @headers.each do |name, value|
          next if name.start_with?(":")
          key = name.upcase.tr("-", "_")
          if key == "CONTENT_TYPE"
            env["CONTENT_TYPE"] = value
          elsif key == "CONTENT_LENGTH"
            env["CONTENT_LENGTH"] = value
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
        headers_received = false

        while offset < buffer.bytesize
          break if buffer.bytesize - offset < 2

          type, type_len = Protocol.decode_varint(buffer.bytes, offset)
          length, length_len = Protocol.decode_varint(buffer.bytes, offset + type_len)
          break if type_len == 0 || length_len == 0

          header_len = type_len + length_len

          break if buffer.bytesize < offset + header_len + length

          payload = buffer[offset + header_len, length]

          if @max_frame_payload_size && length > @max_frame_payload_size
            raise Protocol::FrameError, "Frame payload #{length} exceeds limit #{@max_frame_payload_size}"
          end

          @frames << { type: type, length: length, payload: payload }

          if Protocol::CONTROL_ONLY_FRAMES.include?(type)
            raise Protocol::FrameError, "Frame type 0x#{type.to_s(16)} not allowed on request streams"
          end

          case type
          when 0x01 # HEADERS
            if @max_header_size && length > @max_header_size
              raise Protocol::MessageError, "Header block #{length} exceeds limit #{@max_header_size}"
            end
            parse_headers(payload)
            headers_received = true
          when 0x00 # DATA
            raise Protocol::FrameError, "DATA frame before HEADERS" unless headers_received
            @body.write(payload)
            if @max_body_size && @body.size > @max_body_size
              raise Protocol::MessageError, "Body size #{@body.size} exceeds limit #{@max_body_size}"
            end
          end

          offset += header_len + length
        end

        @body.rewind
      end

      # Decode QPACK header block and validate per RFC 9114 §4.2 and §4.3.1:
      # - Header names MUST be lowercase
      # - Pseudo-headers MUST appear before regular headers
      # - Duplicate pseudo-headers are malformed
      # - Unknown pseudo-headers are malformed
      #
      # QPACK decoding is delegated to @decoder (injectable).
      def parse_headers(payload)
        pseudo_done = false

        @decoder.decode(payload) do |name, value|
          # RFC 9114 §4.2: Header field names MUST be lowercase
          if name =~ /[A-Z]/
            raise Protocol::MessageError, "Header name '#{name}' contains uppercase characters"
          end

          if name.start_with?(":")
            raise Protocol::MessageError, "Pseudo-header '#{name}' after regular header" if pseudo_done

            unless VALID_PSEUDO_HEADERS.include?(name)
              raise Protocol::MessageError, "Unknown pseudo-header '#{name}'"
            end

            if @headers.key?(name)
              raise Protocol::MessageError, "Duplicate pseudo-header '#{name}'"
            end
          else
            pseudo_done = true

            # RFC 9114 §4.2: Connection-specific headers are malformed in HTTP/3
            # Exception: "te: trailers" is permitted (RFC 9114 §4.2)
            if FORBIDDEN_HEADERS.include?(name)
              raise Protocol::MessageError, "Connection-specific header '#{name}' forbidden in HTTP/3" unless name == "te" && value == "trailers"
            end
          end

          store_header(name, value)
        end
      end

      # RFC 9110 §5.3: Combine duplicate header values.
      # - set-cookie: join with "\n" (Rack convention, MUST NOT combine with comma)
      # - cookie: join with "; " (RFC 9114 §4.2.1)
      # - all others: join with ", "
      def store_header(name, value)
        if @headers.key?(name)
          separator = case name
            when "set-cookie" then "\n"
            when "cookie" then "; "
            else ", "
          end
          @headers[name] = "#{@headers[name]}#{separator}#{value}"
        else
          if @max_header_count && @headers.size >= @max_header_count
            raise Protocol::MessageError, "Header count exceeds limit #{@max_header_count}"
          end
          @headers[name] = value
        end
      end
    end
  end
end
