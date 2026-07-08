# frozen_string_literal: true

module Quicsilver
  module Protocol
    module Capsule
      DATAGRAM = 0x00

      class << self
        def encode(type, payload)
          payload = payload.to_s.b
          Protocol.encode_varint(type) + Protocol.encode_varint(payload.bytesize) + payload
        end

        def parse(buffer)
          type, type_length = Protocol.decode_varint_str(buffer, 0)
          return unless type_length > 0

          length, length_length = Protocol.decode_varint_str(buffer, type_length)
          return unless length_length > 0

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
