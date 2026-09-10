# frozen_string_literal: true

module Quicsilver
  module Transport
    # The handle is an opaque native registry token, not a pointer.
    class Stream
      attr_reader :handle

      def initialize(handle)
        @handle = handle
      end

      # Returns the QUIC stream ID. Only available after data has been sent
      # (MsQuic defers ID assignment until data flows on the wire).
      def stream_id
        Quicsilver.get_stream_id(@handle)
      end

      def send(data, fin: false)
        Quicsilver.send_stream(@handle, data, fin)
      end

      def reset(error_code = Protocol::H3_REQUEST_CANCELLED)
        Quicsilver.stream_reset(@handle, error_code)
      end

      def stop_sending(error_code = Protocol::H3_REQUEST_CANCELLED)
        Quicsilver.stream_stop_sending(@handle, error_code)
      end

      def abort(error_code = Protocol::H3_REQUEST_CANCELLED)
        Quicsilver.stream_abort(@handle, error_code)
      end
    end
  end
end
