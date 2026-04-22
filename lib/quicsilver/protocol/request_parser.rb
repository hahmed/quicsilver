# frozen_string_literal: true

require_relative "frame_parser"

module Quicsilver
  module Protocol
    class RequestParser < FrameParser

      # Known HTTP/3 request pseudo-headers (RFC 9114 §4.3.1)
      VALID_PSEUDO_HEADERS = %w[:method :scheme :authority :path :protocol].freeze
      VALID_PSEUDO_SET = VALID_PSEUDO_HEADERS.each_with_object({}) { |h, s| s[h] = true }.freeze

      # Connection-specific headers forbidden in HTTP/3 (RFC 9114 §4.2)
      FORBIDDEN_HEADERS = %w[connection transfer-encoding keep-alive upgrade proxy-connection te].freeze
      FORBIDDEN_SET = FORBIDDEN_HEADERS.each_with_object({}) { |h, s| s[h] = true }.freeze

      # Cache for validated header results: payload → headers hash
      # Only used when no custom limits are set (max_header_count, max_header_size)
      HEADERS_CACHE = {}
      HEADERS_CACHE_MAX = 256

      def initialize(data, **opts)
        decoder = opts.delete(:decoder) || DEFAULT_DECODER
        super(decoder: decoder, max_body_size: opts[:max_body_size],
              max_header_size: opts[:max_header_size],
              max_header_count: opts[:max_header_count],
              max_frame_payload_size: opts[:max_frame_payload_size])
        @data = data
        @use_parse_cache = @decoder.equal?(DEFAULT_DECODER) && !@max_body_size && !@max_header_size && !@max_header_count && !@max_frame_payload_size
      end

      # Reset parser with new data for object reuse (avoids allocation overhead)
      def reset(data)
        @data = data
        @headers = {}
        @trailers = {}
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
        @headers = {}
        @trailers = {}
        @frames = nil
        @body = nil
        @cached_body_str = nil
        parse!
        cache_result if @use_parse_cache
      end

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
        walk_frames(@data)
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
    end
  end
end
