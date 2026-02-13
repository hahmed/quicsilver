# frozen_string_literal: true

module Quicsilver
  # Wraps a QUIC stream opened by Ruby code (client requests, server control streams).
  # Encapsulates the C handle — callers use send/reset/stop_sending methods instead
  # of passing raw pointers to Quicsilver.send_stream etc.
  class Stream
    attr_reader :handle

    def initialize(handle)
      @handle = handle
    end

    def send(data, fin: false)
      Quicsilver.send_stream(@handle, data, fin)
    end

    def reset(error_code = HTTP3::H3_REQUEST_CANCELLED)
      Quicsilver.stream_reset(@handle, error_code)
    end

    def stop_sending(error_code = HTTP3::H3_REQUEST_CANCELLED)
      Quicsilver.stream_stop_sending(@handle, error_code)
    end
  end
end
