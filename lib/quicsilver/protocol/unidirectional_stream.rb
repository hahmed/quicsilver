# frozen_string_literal: true

module Quicsilver
  module Protocol
    module UnidirectionalStream
      CONTROL = 0x00
      PUSH = 0x01
      QPACK_ENCODER = 0x02
      QPACK_DECODER = 0x03
    end
  end
end
