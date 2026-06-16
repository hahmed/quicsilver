# frozen_string_literal: true

module Quicsilver
  module Rack
    # Rack-visible Quicsilver transport context.
    #
    # This is the single env capability object for HTTP/3/QUIC-specific state.
    # Normal Rack apps can ignore it; Quicsilver-aware apps can use it to opt into
    # transport features like WebTransport.
    class Context
      attr_reader :stream_id, :webtransport

      def initialize(stream_id: nil, early_data: false, webtransport: nil, metadata: {})
        @stream_id = stream_id
        @early_data = early_data
        @webtransport = webtransport
        @metadata = metadata || {}
      end

      def early_data?
        !!@early_data
      end

      def webtransport?
        !!@webtransport
      end

      def [](key)
        @metadata[key]
      end
    end
  end
end
