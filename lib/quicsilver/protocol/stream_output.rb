# frozen_string_literal: true


module Quicsilver
  module Protocol
    # Reads from a Protocol::HTTP::Body::Readable response body and writes
    # HTTP/3 DATA frames to the transport.
    #
    # Transport-agnostic: takes a writer block/callable that handles the actual
    # sending. Works with msquic, kernel QUIC sockets, or any transport that
    # can send bytes with a FIN flag.
    #
    class StreamOutput
      # @param body [Protocol::HTTP::Body::Readable] The response body to stream.
      # @param writer [#call] A callable that accepts (data, fin) — sends bytes
      #   to the transport. `fin: true` signals end of stream.
      def initialize(body, &writer)
        @body = body
        @writer = writer
      end

      # Stream all chunks from the response body as HTTP/3 DATA frames.
      #
      # Each chunk is wrapped in an HTTP/3 DATA frame (type 0x00) and sent
      # via the writer. The final chunk is sent with fin=true.
      #
      # @return [void]
      def stream
        last_chunk = nil

        while (chunk = @body.read)
          if last_chunk
            @writer.call(build_data_frame(last_chunk), false)
          end
          last_chunk = chunk
        end

        if last_chunk
          @writer.call(build_data_frame(last_chunk), true)
        else
          @writer.call("".b, true)
        end
      ensure
        @body.close if @body.respond_to?(:close)
      end

      private

      def build_data_frame(payload)
        payload = payload.b
        Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::FRAME_DATA) +
          Quicsilver::Protocol.encode_varint(payload.bytesize) +
          payload
      end
    end
  end
end
