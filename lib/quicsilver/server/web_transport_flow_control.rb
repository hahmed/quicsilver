# frozen_string_literal: true

module Quicsilver
  class Server
    # The limits a peer has granted this session (draft-ietf-webtrans-http3-16
    # §5). Session flow control sits above QUIC's own: QUIC bounds the
    # connection and each stream, this bounds one session across all of its
    # streams.
    #
    # This side of it is what we are permitted to send. What the peer may send
    # us is counted separately, against the limits we advertised.
    #
    # Limits start at the peer's WT_INITIAL_MAX_* settings, default 0, which
    # means nothing can be sent until a capsule raises them (§5.5).
    class WebTransportFlowControl
      WT = Protocol::WebTransport

      attr_reader :max_data, :max_streams_bidi, :max_streams_uni

      def self.from_settings(settings)
        new(
          max_data: settings[Protocol::SETTINGS_WT_INITIAL_MAX_DATA].to_i,
          max_streams_bidi: settings[Protocol::SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI].to_i,
          max_streams_uni: settings[Protocol::SETTINGS_WT_INITIAL_MAX_STREAMS_UNI].to_i
        )
      end

      def initialize(max_data: 0, max_streams_bidi: 0, max_streams_uni: 0)
        @max_data = max_data
        @max_streams_bidi = max_streams_bidi
        @max_streams_uni = max_streams_uni
      end

      # Apply a limit the peer sent. Capsules travel on the CONNECT stream and
      # so arrive in order, which is why a limit that does not increase is an
      # error here where the equivalent QUIC frame would simply be stale
      # (§5.6.2, §5.6.4).
      #
      # The BLOCKED capsules carry a limit too, but it is the sender telling us
      # what it was stuck behind, not a grant, so it changes nothing.
      def apply(limit)
        case limit.kind
        when :max_data then @max_data = increase!(:max_data, @max_data, limit.limit)
        when :max_streams then apply_max_streams(limit)
        when :data_blocked, :streams_blocked then nil
        else raise ArgumentError, "Unknown flow control capsule kind #{limit.kind}"
        end
      end

      def max_streams(direction)
        (direction == :bidi) ? @max_streams_bidi : @max_streams_uni
      end

      private

      def apply_max_streams(limit)
        if limit.direction == :bidi
          @max_streams_bidi = increase!(:max_streams_bidi, @max_streams_bidi, limit.limit)
        else
          @max_streams_uni = increase!(:max_streams_uni, @max_streams_uni, limit.limit)
        end
      end

      # "If an endpoint receives a WT_MAX_DATA capsule with a Maximum Data
      # value that does not increase the Maximum Data value previously
      # received, it MUST close the WebTransport session with a
      # WT_FLOW_CONTROL_ERROR error code." Equal is not an increase.
      def increase!(name, current, value)
        unless value > current
          raise WT::FlowControlError,
            "#{name} of #{value} does not increase the current limit of #{current}"
        end

        value
      end
    end
  end
end
