# frozen_string_literal: true

module Quicsilver
  module Protocol
    # HTTP/3 DATAGRAM payload framing (RFC 9297).
    #
    # The DATAGRAM frame payload starts with a varint quarter stream ID, followed
    # by the application payload. The quarter stream ID is the HTTP/3 stream ID
    # divided by four, matching the client-initiated bidirectional request stream
    # numbering pattern (0, 4, 8, ...).
    module Datagram
      STREAM_ID_DIVISOR = 4

      class << self
        def encode(stream_id, payload)
          Protocol.encode_varint(quarter_stream_id(stream_id)) + payload.to_s.b
        end

        def decode(datagram)
          quarter_stream_id, prefix_length = Protocol.decode_varint_str(datagram, 0)
          return if prefix_length == 0

          [stream_id(quarter_stream_id), payload(datagram, prefix_length)]
        end

        def quarter_stream_id(stream_id)
          stream_id / STREAM_ID_DIVISOR
        end

        def stream_id(quarter_stream_id)
          quarter_stream_id * STREAM_ID_DIVISOR
        end

        def payload(datagram, prefix_length)
          datagram.byteslice(prefix_length..-1) || "".b
        end
      end
    end
  end
end
