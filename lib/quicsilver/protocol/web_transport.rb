# frozen_string_literal: true

module Quicsilver
  module Protocol
    module WebTransport
      SESSION_GONE = 0x170d7b68
      BUFFERED_STREAM_REJECTED = 0x3994bd84

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

      # WebTransport shares the HTTP/3 error space, so 32-bit application error
      # codes are mapped into a reserved range (§4.4, §9.5). Codepoints of the
      # form 0x1f * N + 0x21 are reserved by HTTP/3 §8.1 and skipped, which is
      # why this is not a plain offset.
      APPLICATION_ERROR_FIRST = 0x52e4a40fa8db
      APPLICATION_ERROR_LAST = 0x52e5ac983162

      RESERVED_STRIDE = 0x1f
      RESERVED_OFFSET = 0x21

      # Application code -> HTTP/3 code, stepping over reserved codepoints.
      def self.application_error_to_http(code)
        APPLICATION_ERROR_FIRST + code + (code / 0x1e)
      end

      # HTTP/3 code -> application code. nil when the code is outside the
      # reserved range or lands on a reserved codepoint, neither of which a
      # peer should ever send.
      def self.http_to_application_error(code)
        return nil unless code.between?(APPLICATION_ERROR_FIRST, APPLICATION_ERROR_LAST)
        return nil if reserved_codepoint?(code)

        shifted = code - APPLICATION_ERROR_FIRST
        shifted - (shifted / RESERVED_STRIDE)
      end

      def self.reserved_codepoint?(code)
        (code - RESERVED_OFFSET) % RESERVED_STRIDE == 0
      end
    end
  end
end
