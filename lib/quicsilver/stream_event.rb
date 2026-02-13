# frozen_string_literal: true

module Quicsilver
  # Parses the binary data packed by the C extension for stream completion events.
  # C packs all events as [stream_handle(8 bytes)][payload...] where payload
  # depends on the event type.
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
