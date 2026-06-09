# frozen_string_literal: true

module Quicsilver
  module Transport
    module StreamId
      INITIATOR_MASK = 0x01
      DIRECTION_MASK = 0x02
      REQUEST_STREAM_MASK = INITIATOR_MASK | DIRECTION_MASK

      module_function

      def bidirectional?(stream_id)
        (stream_id & DIRECTION_MASK).zero?
      end

      def unidirectional?(stream_id)
        !bidirectional?(stream_id)
      end

      # HTTP/3 requests run on client-initiated bidirectional QUIC streams.
      def request?(stream_id)
        (stream_id & REQUEST_STREAM_MASK).zero?
      end
    end
  end
end
