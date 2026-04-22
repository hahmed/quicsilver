# frozen_string_literal: true

require "stringio"
require_relative "frame_reader"
require_relative "qpack/header_block_decoder"

module Quicsilver
  module Protocol
    # Base class for HTTP/3 request and response frame parsing.
    #
    # Handles the shared frame walking loop, HEADERS→DATA→HEADERS ordering,
    # trailer parsing, body accumulation, and size limit enforcement.
    #
    # Subclasses implement:
    #   - parse_headers(payload) — decode the first HEADERS frame
    class FrameParser
      # Frame types forbidden on request streams — use hash for O(1) lookup
      # Static-only QPACK decoder (no dynamic table). Used by default.
      # Inject a custom decoder via decoder: kwarg for dynamic QPACK support.
      DEFAULT_DECODER = Qpack::HeaderBlockDecoder.default

      CONTROL_ONLY_SET = Protocol::CONTROL_ONLY_FRAMES.each_with_object({}) { |f, h| h[f] = true }.freeze

      EMPTY_BODY = StringIO.new("".b).tap { |io| io.set_encoding(Encoding::ASCII_8BIT) }

      attr_reader :headers, :trailers, :bytes_consumed

      def frames
        @frames || []
      end

      def initialize(decoder:, max_body_size: nil, max_header_size: nil, max_header_count: nil, max_frame_payload_size: nil)
        @decoder = decoder
        @max_body_size = max_body_size
        @max_header_size = max_header_size
        @max_header_count = max_header_count
        @max_frame_payload_size = max_frame_payload_size
        @headers = {}
        @trailers = {}
      end

      def frames
        @frames || []
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

      private

      def parse!
        walk_frames(@data)
      end

      def walk_frames(buffer)
        @headers = {}
        @trailers = {}
        @body = nil
        @frames = nil
        @bytes_consumed = 0
        headers_received = false
        trailers_received = false

        @bytes_consumed = FrameReader.each(buffer) do |type, payload|
          if @max_frame_payload_size && payload.bytesize > @max_frame_payload_size
            raise Protocol::FrameError, "Frame payload #{payload.bytesize} exceeds limit #{@max_frame_payload_size}"
          end

          (@frames ||= []) << { type: type, length: payload.bytesize, payload: payload }

          if CONTROL_ONLY_SET.key?(type)
            raise Protocol::FrameError, "Frame type 0x#{type.to_s(16)} not allowed on request streams"
          end

          case type
          when 0x01 # HEADERS
            if @max_header_size && payload.bytesize > @max_header_size
              raise Protocol::MessageError, "Header block #{payload.bytesize} exceeds limit #{@max_header_size}"
            end
            if trailers_received
              raise Protocol::FrameError, "HEADERS frame after trailers"
            elsif headers_received
              parse_trailers(payload)
              trailers_received = true
            else
              parse_headers(payload)
              headers_received = true
            end
          when 0x00 # DATA
            raise Protocol::FrameError, "DATA frame before HEADERS" unless headers_received
            raise Protocol::FrameError, "DATA frame after trailers" if trailers_received
            unless @body
              @body = StringIO.new
              @body.set_encoding(Encoding::ASCII_8BIT)
            end
            @body.write(payload)
            if @max_body_size && @body.size > @max_body_size
              raise Protocol::MessageError, "Body size #{@body.size} exceeds limit #{@max_body_size}"
            end
          end
        end

        @body&.rewind
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

      def parse_trailers(payload)
        @decoder.decode(payload) do |name, value|
          if name.start_with?(":")
            raise Protocol::MessageError, "Pseudo-header '#{name}' in trailers"
          end
          @trailers[name] = value
        end
      end
    end
  end
end
