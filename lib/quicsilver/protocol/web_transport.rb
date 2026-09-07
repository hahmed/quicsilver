# frozen_string_literal: true

module Quicsilver
  module Protocol
    module WebTransport
      BIDI_STREAM_TYPE = 0x41
      UNI_STREAM_TYPE = 0x54
      CLOSE_SESSION_CAPSULE = 0x2843

      # draft-ietf-webtrans-http3-16 §4.7. Advisory: either endpoint asks the
      # other to wind the session down, but the session stays usable until it
      # is actually closed.
      DRAIN_SESSION_CAPSULE = 0x78ae

      # Extended CONNECT :protocol values.
      #
      # draft-ietf-webtrans-http3-16 §3.2 requires "webtransport-h3". The bare
      # "webtransport" token identifies the capsule-based HTTP/2 binding
      # (§2.1.2) and was what pre-15 drafts used over HTTP/3; Chrome still
      # sends it, so both are accepted.
      PROTOCOL = "webtransport-h3"
      PROTOCOL_LEGACY = "webtransport"

      def self.protocol?(value)
        value == PROTOCOL || value == PROTOCOL_LEGACY
      end
    end
  end
end
