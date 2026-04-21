# frozen_string_literal: true

require_relative "frame_parser"

module Quicsilver
  module Protocol
    class ResponseParser < FrameParser
      attr_reader :status

      DEFAULT_DECODER = Qpack::HeaderBlockDecoder.default

      def initialize(data, **opts)
        decoder = opts.delete(:decoder) || DEFAULT_DECODER
        super(decoder: decoder, max_body_size: opts[:max_body_size],
              max_header_size: opts[:max_header_size])
        @data = data
        @use_parse_cache = @decoder.equal?(DEFAULT_DECODER) && !@max_body_size && !@max_header_size
      end

      # Reset parser with new data for object reuse (avoids allocation overhead)
      def reset(data)
        @data = data
        @status = nil
        @headers = {}
        @trailers = {}
        @frames = nil
        @body = nil
        @cached_body_str = nil
      end

      # Combined reset + parse for maximum throughput (single method call)
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
            @status = cached[0]
            @headers = cached[1]
            @frames = cached[2]
            @cached_body_str = cached[3]
            @last_data = data
            return
          end
        end
        @status = nil
        @headers = {}
        @trailers = {}
        @frames = nil
        @body = nil
        @cached_body_str = nil
        parse!
        cache_result if @use_parse_cache
      end

      def body
        if @body
          @body.rewind
          @body
        elsif @cached_body_str
          @body = StringIO.new(@cached_body_str)
          @body.set_encoding(Encoding::ASCII_8BIT)
          @body
        else
          EMPTY_BODY
        end
      end

      # Class-level parse result cache: data → [status, headers, frames, body_str]
      PARSE_CACHE = {}
      PARSE_CACHE_MAX = 128
      PARSE_OID_CACHE = {}
      PARSE_OID_CACHE_MAX = 128

      def parse
        # Fast path: full parse result cache for default decoder with no limits
        if @use_parse_cache
          cached = PARSE_CACHE[@data]
          if cached
            @status = cached[0]
            @headers = cached[1]
            @frames = cached[2]
            @cached_body_str = cached[3]
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
          key = @data.frozen? ? @data : @data.dup.freeze
          PARSE_CACHE[key] = [
            @status,
            @headers.dup.freeze,
            (@frames || []).freeze,
            body_str&.freeze
          ].freeze
        end
      end

      private

      def parse!
        result = walk_frames(@data)
        @body = result.body
        @frames = result.frames
      end

      # Cache for validated response header results
      HEADERS_CACHE = {}
      HEADERS_CACHE_MAX = 256

      # Decode QPACK header block via injectable @decoder.
      # Extracts :status pseudo-header into @status.
      def parse_headers(payload)
        use_cache = @decoder.equal?(DEFAULT_DECODER)

        if use_cache
          cached = HEADERS_CACHE[payload]
          if cached
            @status = cached[:status]
            @headers.merge!(cached[:headers])
            return
          end
        end

        @decoder.decode(payload) do |name, value|
          if name == ":status"
            @status = value.to_i
          else
            store_header(name, value)
          end
        end

        # Cache the result
        if use_cache && HEADERS_CACHE.size < HEADERS_CACHE_MAX && payload.bytesize <= 512
          key = payload.frozen? ? payload : payload.dup.freeze
          HEADERS_CACHE[key] = { status: @status, headers: @headers.dup.freeze }.freeze
        end
      end
    end
  end
end
