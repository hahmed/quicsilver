# frozen_string_literal: true

module Quicsilver
  module Transport
    # Parses the binary data packed by the C extension for stream completion events.
    # C packs events as:
    #   RECEIVE_FIN:  [stream_handle(8)][payload...]
    #   STREAM_RESET: [stream_handle(8)][error_code(8)][final_size(8)]
    #   STOP_SENDING: [stream_handle(8)][error_code(8)]
    class StreamEvent
      # A reset stream's final size is unknown to MsQuic until RESET_STREAM or
      # FIN settles it; the C extension reports that as this sentinel so it
      # never has to be confused with a real length.
      FINAL_SIZE_UNKNOWN = (2**64) - 1

      attr_reader :handle, :data, :error_code

      # The total number of bytes the peer sent on this stream, from the
      # RESET_STREAM frame (RFC 9000 4.5). nil when it is not settled or the
      # event does not carry one. WebTransport session flow control needs it to
      # charge the bytes a reset discarded (draft-ietf-webtrans-http3-16 5.4).
      attr_reader :final_size

      def initialize(raw_data, event_type)
        @handle = raw_data[0, 8].unpack1("Q")
        remaining = raw_data[8..] || "".b

        case event_type
        when "RECEIVE", "RECEIVE_FIN"
          @data = remaining
        when "STREAM_RESET", "STOP_SENDING"
          @error_code = remaining.unpack1("Q")
          @final_size = parse_final_size(remaining)
        end
      end

      private

      # Older packings carry only the error code, so a missing final size is
      # not an error.
      def parse_final_size(remaining)
        return unless remaining.bytesize >= 16

        value = remaining.unpack1("@8Q")
        value unless value == FINAL_SIZE_UNKNOWN
      end
    end
  end
end
