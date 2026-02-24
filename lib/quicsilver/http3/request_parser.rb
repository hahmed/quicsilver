# frozen_string_literal: true

require "stringio"
require_relative "../qpack/header_block_decoder"

module Quicsilver
  module HTTP3
    class RequestParser
      attr_reader :frames, :headers, :body

      # Known HTTP/3 request pseudo-headers (RFC 9114 §4.3.1)
      VALID_PSEUDO_HEADERS = %w[:method :scheme :authority :path :protocol].freeze

      def initialize(data, decoder: Qpack::HeaderBlockDecoder.new)
        @data = data
        @decoder = decoder
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
          raise HTTP3::MessageError, "CONNECT request must include :authority" unless @headers[":authority"]
          raise HTTP3::MessageError, "CONNECT request must not include :scheme" if @headers[":scheme"]
          raise HTTP3::MessageError, "CONNECT request must not include :path" if @headers[":path"]
        else
          raise HTTP3::MessageError, "Request missing required pseudo-header :method" unless method
          raise HTTP3::MessageError, "Request missing required pseudo-header :scheme" unless @headers[":scheme"]
          raise HTTP3::MessageError, "Request missing required pseudo-header :path" unless @headers[":path"]
        end

        # Host and :authority consistency (RFC 9114 §4.3.1)
        if @headers[":authority"] && @headers["host"]
          unless @headers[":authority"] == @headers["host"]
            raise HTTP3::MessageError, ":authority and host header must be consistent"
          end
        end

        # Content-length vs body size (RFC 9114 §4.1.2)
        if @headers["content-length"]
          expected = @headers["content-length"].to_i
          actual = @body.size
          unless expected == actual
            raise HTTP3::MessageError, "Content-length mismatch: header=#{expected}, body=#{actual}"
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

          type, type_len = HTTP3.decode_varint(buffer.bytes, offset)
          length, length_len = HTTP3.decode_varint(buffer.bytes, offset + type_len)
          break if type_len == 0 || length_len == 0

          header_len = type_len + length_len

          break if buffer.bytesize < offset + header_len + length

          payload = buffer[offset + header_len, length]
          @frames << { type: type, length: length, payload: payload }

          if HTTP3::CONTROL_ONLY_FRAMES.include?(type)
            raise HTTP3::FrameError, "Frame type 0x#{type.to_s(16)} not allowed on request streams"
          end

          case type
          when 0x01 # HEADERS
            parse_headers(payload)
            headers_received = true
          when 0x00 # DATA
            raise HTTP3::FrameError, "DATA frame before HEADERS" unless headers_received
            @body.write(payload)
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
            raise HTTP3::MessageError, "Header name '#{name}' contains uppercase characters"
          end

          if name.start_with?(":")
            raise HTTP3::MessageError, "Pseudo-header '#{name}' after regular header" if pseudo_done

            unless VALID_PSEUDO_HEADERS.include?(name)
              raise HTTP3::MessageError, "Unknown pseudo-header '#{name}'"
            end

            if @headers.key?(name)
              raise HTTP3::MessageError, "Duplicate pseudo-header '#{name}'"
            end
          else
            pseudo_done = true
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
          @headers[name] = value
        end
      end
    end
  end
end
