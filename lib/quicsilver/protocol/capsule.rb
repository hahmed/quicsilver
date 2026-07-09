# frozen_string_literal: true

module Quicsilver
  module Protocol
    module Capsule
      DATAGRAM = 0x00
      MAX_PAYLOAD_SIZE = 1_048_576

      ParseError = Class.new(StandardError)
      PayloadTooLarge = Class.new(ParseError)

      class << self
        def encode(type, payload)
          payload = payload.to_s.b
          Protocol.encode_varint(type) + Protocol.encode_varint(payload.bytesize) + payload
        end

        def parse(buffer, max_payload_size: MAX_PAYLOAD_SIZE)
          type, type_length = Protocol.decode_varint_str(buffer, 0)
          return unless type_length > 0

          length, length_length = Protocol.decode_varint_str(buffer, type_length)
          return unless length_length > 0

          raise PayloadTooLarge, "Capsule payload too large" if length > max_payload_size

          header_length = type_length + length_length
          return if buffer.bytesize < header_length + length

          payload = buffer.byteslice(header_length, length) || "".b
          remainder = buffer.byteslice(header_length + length..-1) || "".b

          [type, payload, remainder]
        end
      end
    end
  end
end
