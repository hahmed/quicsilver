# frozen_string_literal: true

require "stringio"
require_relative "qpack/header_block_decoder"

module Quicsilver
  module Protocol
    class RequestParser
      attr_reader :headers, :bytes_consumed

      def frames
        @frames || []
      end

      # Known HTTP/3 request pseudo-headers (RFC 9114 §4.3.1)
      VALID_PSEUDO_HEADERS = %w[:method :scheme :authority :path :protocol].freeze
      VALID_PSEUDO_SET = VALID_PSEUDO_HEADERS.each_with_object({}) { |h, s| s[h] = true }.freeze

      # Connection-specific headers forbidden in HTTP/3 (RFC 9114 §4.2)
      FORBIDDEN_HEADERS = %w[connection transfer-encoding keep-alive upgrade proxy-connection te].freeze
      FORBIDDEN_SET = FORBIDDEN_HEADERS.each_with_object({}) { |h, s| s[h] = true }.freeze

      # Frame types forbidden on request streams — use Set-like hash for O(1) lookup
      CONTROL_ONLY_SET = Protocol::CONTROL_ONLY_FRAMES.each_with_object({}) { |f, h| h[f] = true }.freeze

      # Cache for validated header results: payload → headers hash
      # Only used when no custom limits are set (max_header_count, max_header_size)
      HEADERS_CACHE = {}
      HEADERS_CACHE_MAX = 256

      DEFAULT_DECODER = Qpack::HeaderBlockDecoder.default

      def initialize(data, **opts)
        @data = data
        if opts.empty?
          @decoder = DEFAULT_DECODER
          @use_parse_cache = true
        else
          @decoder = opts[:decoder] || DEFAULT_DECODER
          @max_body_size = opts[:max_body_size]
          @max_header_size = opts[:max_header_size]
          @max_header_count = opts[:max_header_count]
          @max_frame_payload_size = opts[:max_frame_payload_size]
          @use_parse_cache = @decoder.equal?(DEFAULT_DECODER) && !@max_body_size && !@max_header_size && !@max_header_count && !@max_frame_payload_size
        end
      end

      # Reset parser with new data for object reuse (avoids allocation overhead)
      def reset(data)
        @data = data
        @headers = nil
        @frames = nil
        @body = nil
        @cached_body_str = nil
      end

      # Combined reset + parse for maximum throughput (single method call)
      # Cache values stored as [headers, frames, body_str] for fast index access
      def reparse(data)
        @data = data
        # Fastest path: same data object as last time — skip all cache lookups
        return if data.equal?(@last_data) && @headers

        if @use_parse_cache
          oid = data.object_id
          cached = PARSE_OID_CACHE[oid]
          unless cached
            cached = PARSE_CACHE[data]
            PARSE_OID_CACHE[oid] = cached if cached && PARSE_OID_CACHE.size < PARSE_OID_CACHE_MAX
          end
          if cached
            @headers = cached[0]
            @frames = cached[1]
            @cached_body_str = cached[2]
            @last_data = data
            return
          end
        end
        @headers = nil
        @frames = nil
        @body = nil
        @cached_body_str = nil
        parse!
        cache_result if @use_parse_cache
      end

      def body
        if @body
          @body
        elsif @cached_body_str
          @body = StringIO.new(@cached_body_str)
          @body.set_encoding(Encoding::ASCII_8BIT)
          @body
        else
          EMPTY_BODY
        end
      end

      EMPTY_BODY = StringIO.new("".b).tap { |io| io.set_encoding(Encoding::ASCII_8BIT) }

      # Class-level parse result cache
      PARSE_CACHE = {}
      PARSE_CACHE_MAX = 128
      # Object-id fast-path for reparse (integer key = faster hash lookup)
      PARSE_OID_CACHE = {}
      PARSE_OID_CACHE_MAX = 128

      def parse
        # Fast path: full parse result cache for default decoder with no limits
        if @use_parse_cache
          cached = PARSE_CACHE[@data]
          if cached
            @headers = cached[0]
            @frames = cached[1]
            @cached_body_str = cached[2]
            return
          end
        end

        parse!
        cache_result if @use_parse_cache
      end

      private def cache_result
        if PARSE_CACHE.size < PARSE_CACHE_MAX && @data.bytesize <= 1024
          body_str = if @body
            @body.rewind
            s = @body.read
            @body.rewind
            s
          end
          body_str = nil if body_str&.empty?
          key = @data.frozen? ? @data : @data.dup.freeze
          PARSE_CACHE[key] = [
            @headers.dup.freeze,
            (@frames || []).freeze,
            body_str&.freeze
          ].freeze
        end
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
          "rack.input" => body,
          "rack.errors" => $stderr,
          "rack.multithread" => true,
          "rack.multiprocess" => false,
          "rack.run_once" => false,
          "rack.hijack?" => false,
          "SCRIPT_NAME" => "",
          "CONTENT_LENGTH" => body.size.to_s,
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
        @headers = {}
        @bytes_consumed = 0
        buffer = @data
        offset = 0
        headers_received = false
        buf_size = buffer.bytesize

        while offset < buf_size
          break if buf_size - offset < 2

          # Inline single-byte varint fast path (covers frame types 0x00-0x3F)
          type_byte = buffer.getbyte(offset)
          if type_byte < 0x40
            type = type_byte
            type_len = 1
          else
            type, type_len = Protocol.decode_varint_str(buffer, offset)
          end

          len_byte = buffer.getbyte(offset + type_len)
          if len_byte < 0x40
            length = len_byte
            length_len = 1
          else
            length, length_len = Protocol.decode_varint_str(buffer, offset + type_len)
            break if length_len == 0
          end
          break if type_len == 0

          header_len = type_len + length_len

          break if buf_size < offset + header_len + length

          payload = buffer.byteslice(offset + header_len, length)

          if @max_frame_payload_size && length > @max_frame_payload_size
            raise Protocol::FrameError, "Frame payload #{length} exceeds limit #{@max_frame_payload_size}"
          end

          (@frames ||= []) << { type: type, length: length, payload: payload }

          if CONTROL_ONLY_SET.key?(type)
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
            unless @body
              @body = StringIO.new
              @body.set_encoding(Encoding::ASCII_8BIT)
            end
            @body.write(payload)
            if @max_body_size && @body.size > @max_body_size
              raise Protocol::MessageError, "Body size #{@body.size} exceeds limit #{@max_body_size}"
            end
          end

          offset += header_len + length
        end

        @bytes_consumed = offset
        @body&.rewind
      end

      # Decode QPACK header block and validate per RFC 9114 §4.2 and §4.3.1:
      # - Header names MUST be lowercase
      # - Pseudo-headers MUST appear before regular headers
      # - Duplicate pseudo-headers are malformed
      # - Unknown pseudo-headers are malformed
      #
      # QPACK decoding is delegated to @decoder (injectable).
      def parse_headers(payload)
        # Fast path: check validated headers cache (only when no custom limits and default decoder)
        use_cache = !@max_header_count && @decoder.equal?(DEFAULT_DECODER)
        if use_cache
          cached = HEADERS_CACHE[payload]
          if cached
            @headers.merge!(cached)
            return
          end
        end

        pseudo_done = false

        @decoder.decode(payload) do |name, value|
          # RFC 9114 §4.2: Header field names MUST be lowercase
          if name =~ /[A-Z]/
            raise Protocol::MessageError, "Header name '#{name}' contains uppercase characters"
          end

          if name.getbyte(0) == 58 # ':'
            raise Protocol::MessageError, "Pseudo-header '#{name}' after regular header" if pseudo_done

            unless VALID_PSEUDO_SET.key?(name)
              raise Protocol::MessageError, "Unknown pseudo-header '#{name}'"
            end

            if @headers.key?(name)
              raise Protocol::MessageError, "Duplicate pseudo-header '#{name}'"
            end
          else
            pseudo_done = true

            # RFC 9114 §4.2: Connection-specific headers are malformed in HTTP/3
            # Exception: "te: trailers" is permitted (RFC 9114 §4.2)
            if FORBIDDEN_SET.key?(name)
              raise Protocol::MessageError, "Connection-specific header '#{name}' forbidden in HTTP/3" unless name == "te" && value == "trailers"
            end
          end

          store_header(name, value)
        end

        # Cache the validated result
        if use_cache && HEADERS_CACHE.size < HEADERS_CACHE_MAX && payload.bytesize <= 512
          key = payload.frozen? ? payload : payload.dup.freeze
          HEADERS_CACHE[key] = @headers.dup.freeze
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
