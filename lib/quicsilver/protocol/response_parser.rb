# frozen_string_literal: true

require "stringio"
require_relative "qpack/header_block_decoder"

module Quicsilver
  module Protocol
    class ResponseParser
      attr_reader :frames, :headers, :status

      def initialize(data, decoder: Qpack::HeaderBlockDecoder.new,
                     max_body_size: nil, max_header_size: nil)
        @data = data
        @decoder = decoder
        @max_body_size = max_body_size
        @max_header_size = max_header_size
        @frames = []
        @headers = {}
        @body_io = StringIO.new
        @status = nil
      end

      def body
        @body_io.rewind
        @body_io
      end

      def parse
        parse!
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
            @body_io.write(payload)
            if @max_body_size && @body_io.size > @max_body_size
              raise Protocol::MessageError, "Body size #{@body_io.size} exceeds limit #{@max_body_size}"
            end
          end

          offset += header_len + length
        end
      end

      # Decode QPACK header block via injectable @decoder.
      # Extracts :status pseudo-header into @status.
      def parse_headers(payload)
        @decoder.decode(payload) do |name, value|
          if name == ":status"
            @status = value.to_i
          else
            store_header(name, value)
          end
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
