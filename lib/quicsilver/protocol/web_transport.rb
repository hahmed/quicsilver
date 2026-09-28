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

      # Session-level flow control (§5.6). These sit above QUIC's own limits:
      # QUIC bounds the connection and each stream, these bound one session
      # across all of its streams.
      #
      # MAX_* raise a limit. *_BLOCKED are advisory, saying a limit was hit;
      # §5.6 forbids waiting for one before raising a limit.
      MAX_DATA_CAPSULE = 0x190B4D3D
      MAX_STREAMS_BIDI_CAPSULE = 0x190B4D3F
      MAX_STREAMS_UNI_CAPSULE = 0x190B4D40
      DATA_BLOCKED_CAPSULE = 0x190B4D41
      STREAMS_BLOCKED_BIDI_CAPSULE = 0x190B4D43
      STREAMS_BLOCKED_UNI_CAPSULE = 0x190B4D44

      # A flow control violation closes the session, not the connection (§5.6).
      FLOW_CONTROL_ERROR = 0x045d4487

      # Per-stream data limits belong to the HTTP/2 binding. Over HTTP/3 every
      # WebTransport stream is a real QUIC stream, so QUIC provides them
      # natively and these two capsules are prohibited: receipt is a session
      # error (§5.4).
      #
      # Defined in draft-ietf-webtrans-http2-14 §6.6 and §6.9, which the HTTP/3
      # draft cites without restating the code points. They fill the two gaps
      # in the 0x190B4D3D..0x190B4D44 block the §9.6 registry allocates.
      #
      # That draft is not in docs/specs, so these are the only values here
      # without a local citation. Re-verify them when it is vendored.
      MAX_STREAM_DATA_CAPSULE = 0x190B4D3E
      STREAM_DATA_BLOCKED_CAPSULE = 0x190B4D42

      PROHIBITED_CAPSULES = [MAX_STREAM_DATA_CAPSULE, STREAM_DATA_BLOCKED_CAPSULE].freeze

      # Prohibited whether or not flow control was negotiated. §5.1 says to
      # ignore "flow control capsules" when flow control is off, but §5.6
      # defines that term as MAX_DATA, MAX_STREAMS, DATA_BLOCKED and
      # STREAMS_BLOCKED only. These two are never legal over HTTP/3.
      def self.prohibited_capsule?(type)
        PROHIBITED_CAPSULES.include?(type)
      end

      # Stream limits cannot exceed 2^60: a larger count could not be encoded
      # as a stream ID (§5.6.2, §5.6.3).
      MAX_STREAMS_LIMIT = 1 << 60

      # Largest value a QUIC variable-length integer can carry (RFC 9000 §16).
      VARINT_MAX = (1 << 62) - 1

      # Raised for a capsule whose contents break a flow control rule, as
      # opposed to one we cannot parse. The session is closed with
      # FLOW_CONTROL_ERROR; the connection survives.
      class FlowControlError < StandardError
        def error_code = FLOW_CONTROL_ERROR
      end

      # We wanted to send but the peer's session limit forbids it (§5.3,
      # §5.4). Local and recoverable: nothing is wrong on the wire, there is
      # simply no credit. Distinct from FlowControlError, which means the peer
      # broke a rule and the session must close.
      class SendBlocked < StandardError
        attr_reader :limit, :needed

        def initialize(message, limit:, needed:)
          super(message)
          @limit = limit
          @needed = needed
        end
      end

      # What a flow control capsule says. `limit` is cumulative for MAX_DATA
      # and MAX_STREAMS, and for the BLOCKED capsules it is the limit that was
      # in force when the sender was blocked.
      Limit = Data.define(:kind, :direction, :limit) do
        def max? = kind == :max_data || kind == :max_streams
        def blocked? = !max?
      end

      # kind and direction for each flow control capsule type. Direction is nil
      # where the capsule covers the whole session rather than one stream type.
      FLOW_CONTROL_CAPSULES = {
        MAX_DATA_CAPSULE => [:max_data, nil],
        MAX_STREAMS_BIDI_CAPSULE => [:max_streams, :bidi],
        MAX_STREAMS_UNI_CAPSULE => [:max_streams, :uni],
        DATA_BLOCKED_CAPSULE => [:data_blocked, nil],
        STREAMS_BLOCKED_BIDI_CAPSULE => [:streams_blocked, :bidi],
        STREAMS_BLOCKED_UNI_CAPSULE => [:streams_blocked, :uni]
      }.freeze

      def self.flow_control_capsule?(type)
        FLOW_CONTROL_CAPSULES.key?(type)
      end

      # Decode a flow control capsule payload: a single varint (§5.6.2-5.6.5).
      #
      # Raises Capsule::ParseError when the payload is not exactly one varint,
      # and FlowControlError when a stream count exceeds what a stream ID can
      # encode. Those are different outcomes on the wire: the first is a
      # malformed message, the second a flow control violation.
      def self.parse_flow_control_capsule(type, payload)
        kind, direction = FLOW_CONTROL_CAPSULES.fetch(type) do
          raise ArgumentError, "Not a flow control capsule: 0x#{type.to_s(16)}"
        end

        value, length = Protocol.decode_varint_str(payload, 0)
        raise Capsule::ParseError, "Truncated #{kind} capsule" if length == 0
        raise Capsule::ParseError, "Trailing bytes in #{kind} capsule" unless length == payload.bytesize

        if (kind == :max_streams || kind == :streams_blocked) && value > MAX_STREAMS_LIMIT
          raise FlowControlError, "#{kind} of #{value} exceeds the 2^60 stream limit"
        end

        Limit.new(kind: kind, direction: direction, limit: value)
      end

      def self.build_max_data(limit)
        Capsule.encode(MAX_DATA_CAPSULE, Protocol.encode_varint(validate_limit!(limit)))
      end

      def self.build_data_blocked(limit)
        Capsule.encode(DATA_BLOCKED_CAPSULE, Protocol.encode_varint(validate_limit!(limit)))
      end

      def self.build_max_streams(direction, limit)
        type = (direction == :bidi) ? MAX_STREAMS_BIDI_CAPSULE : MAX_STREAMS_UNI_CAPSULE
        Capsule.encode(type, Protocol.encode_varint(validate_stream_limit!(direction, limit)))
      end

      def self.build_streams_blocked(direction, limit)
        type = (direction == :bidi) ? STREAMS_BLOCKED_BIDI_CAPSULE : STREAMS_BLOCKED_UNI_CAPSULE
        Capsule.encode(type, Protocol.encode_varint(validate_stream_limit!(direction, limit)))
      end

      # Building a capsule the peer would have to reject is our bug, so these
      # raise ArgumentError rather than a protocol error.
      def self.validate_limit!(limit)
        unless limit.is_a?(Integer) && limit >= 0 && limit <= VARINT_MAX
          raise ArgumentError, "Limit must be a varint-encodable non-negative integer"
        end

        limit
      end

      def self.validate_stream_limit!(direction, limit)
        unless direction == :bidi || direction == :uni
          raise ArgumentError, "Direction must be :bidi or :uni"
        end
        validate_limit!(limit)
        raise ArgumentError, "Stream limit #{limit} exceeds 2^60" if limit > MAX_STREAMS_LIMIT

        limit
      end

      # Extended CONNECT :protocol values.
      #
      # draft-ietf-webtrans-http3-16 §3.2 requires "webtransport-h3". The bare
      # "webtransport" token identifies the capsule-based HTTP/2 binding
      # (§2.1.2) and was what pre-15 drafts used over HTTP/3. We retain it
      # for legacy interoperability; the token alone does not identify a
      # browser version or prove support for every feature of an older draft.
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
