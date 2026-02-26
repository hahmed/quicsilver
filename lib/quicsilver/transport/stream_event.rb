# frozen_string_literal: true

module Quicsilver
  module Transport
    # Parses the binary data packed by the C extension for stream completion events.
    # C packs events as:
    #   RECEIVE_FIN:  [stream_handle(8)][payload...]
    #   STREAM_RESET: [stream_handle(8)][error_code(8)]
    #   STOP_SENDING: [stream_handle(8)][error_code(8)]
    class StreamEvent
      attr_reader :handle, :data, :error_code

      def initialize(raw_data, event_type)
        @handle = raw_data[0, 8].unpack1("Q")
        remaining = raw_data[8..] || "".b

        case event_type
        when "RECEIVE_FIN"
          @data = remaining
        when "STREAM_RESET", "STOP_SENDING"
          @error_code = remaining.unpack1("Q")
        end
      end
    end
  end
end
