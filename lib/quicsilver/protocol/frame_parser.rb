# frozen_string_literal: true

require "stringio"
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
      CONTROL_ONLY_SET = Protocol::CONTROL_ONLY_FRAMES.each_with_object({}) { |f, h| h[f] = true }.freeze

      FrameResult = Struct.new(:headers, :trailers, :body, :frames, :bytes_consumed, keyword_init: true)
      EMPTY_BODY = StringIO.new("".b).tap { |io| io.set_encoding(Encoding::ASCII_8BIT) }

      attr_reader :headers, :trailers

      def initialize(decoder:, max_body_size: nil, max_header_size: nil, max_frame_payload_size: nil)
        @decoder = decoder
        @max_body_size = max_body_size
        @max_header_size = max_header_size
        @max_frame_payload_size = max_frame_payload_size
        @headers = {}
        @trailers = {}
      end

      def frames
        @frames || []
      end

      private

      def walk_frames(buffer)
        @headers = {}
        @trailers = {}
        body = nil
        frames = nil
        headers_received = false
        trailers_received = false
        offset = 0
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

          (frames ||= []) << { type: type, length: length, payload: payload }

          if CONTROL_ONLY_SET.key?(type)
            raise Protocol::FrameError, "Frame type 0x#{type.to_s(16)} not allowed on request streams"
          end

          case type
          when 0x01 # HEADERS
            if @max_header_size && length > @max_header_size
              raise Protocol::MessageError, "Header block #{length} exceeds limit #{@max_header_size}"
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
            unless body
              body = StringIO.new
              body.set_encoding(Encoding::ASCII_8BIT)
            end
            body.write(payload)
            if @max_body_size && body.size > @max_body_size
              raise Protocol::MessageError, "Body size #{body.size} exceeds limit #{@max_body_size}"
            end
          end

          offset += header_len + length
        end

        body&.rewind

        FrameResult.new(
          headers: @headers,
          trailers: @trailers,
          body: body,
          frames: frames || [],
          bytes_consumed: offset
        )
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
