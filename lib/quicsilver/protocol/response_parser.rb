# frozen_string_literal: true

require "stringio"
require_relative "qpack/header_block_decoder"

module Quicsilver
  module Protocol
    class ResponseParser
      attr_reader :headers, :status

      def frames
        @frames || []
      end

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
          @use_parse_cache = @decoder.equal?(DEFAULT_DECODER) && !@max_body_size && !@max_header_size
        end
      end

      # Reset parser with new data for object reuse (avoids allocation overhead)
      def reset(data)
        @data = data
        @status = nil
        @headers = nil
        @frames = nil
        @body_io = nil
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
        @headers = nil
        @frames = nil
        @body_io = nil
        @cached_body_str = nil
        parse!
        cache_result if @use_parse_cache
      end

      def body
        if @body_io
          @body_io.rewind
          @body_io
        elsif @cached_body_str
          @body_io = StringIO.new(@cached_body_str)
          @body_io.set_encoding(Encoding::ASCII_8BIT)
          @body_io
        else
          EMPTY_BODY
        end
      end

      EMPTY_BODY = StringIO.new("".b).tap { |io| io.set_encoding(Encoding::ASCII_8BIT) }

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
          body_str = if @body_io
            @body_io.rewind
            s = @body_io.read
            @body_io.rewind
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

      # Frame types forbidden on request streams — O(1) lookup
      CONTROL_ONLY_SET = Protocol::CONTROL_ONLY_FRAMES.each_with_object({}) { |f, h| h[f] = true }.freeze

      def parse!
        @headers = {}
        @status = nil
        @body_io = nil
        @frames = nil
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
            unless @body_io
              @body_io = StringIO.new
              @body_io.set_encoding(Encoding::ASCII_8BIT)
            end
            @body_io.write(payload)
            if @max_body_size && @body_io.size > @max_body_size
              raise Protocol::MessageError, "Body size #{@body_io.size} exceeds limit #{@max_body_size}"
            end
          end

          offset += header_len + length
        end
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
