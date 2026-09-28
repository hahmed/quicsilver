# frozen_string_literal: true

module Quicsilver
  class Server
    # The limits a peer has granted this session (draft-ietf-webtrans-http3-16
    # §5). Session flow control sits above QUIC's own: QUIC bounds the
    # connection and each stream, this bounds one session across all of its
    # streams.
    #
    # This is what we are permitted to send. WebTransportReceiveLimits below
    # is the mirror: what the peer may send us, against limits we advertised.
    # The two are kept apart because the rules differ. A granted limit must
    # increase and is never spent here; an advertised one is spent and never
    # moves on its own.
    #
    # Limits start at the peer's WT_INITIAL_MAX_* settings, default 0, which
    # means nothing can be sent until a capsule raises them (§5.5).
    class WebTransportFlowControl
      WT = Protocol::WebTransport

      attr_reader :max_data, :max_streams_bidi, :max_streams_uni
      attr_reader :data_sent

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
        @data_sent = 0
        @streams_opened_bidi = 0
        @streams_opened_uni = 0
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

      def streams_opened(direction)
        (direction == :bidi) ? @streams_opened_bidi : @streams_opened_uni
      end

      # "An endpoint MUST NOT open more streams than permitted by the current
      # stream limit set by its peer" (§5.6.2). The limit counts closed
      # streams too, so this only ever rises.
      def open_stream!(direction)
        opened = streams_opened(direction)
        limit = max_streams(direction)
        if opened + 1 > limit
          raise WT::SendBlocked.new(
            "cannot open a #{direction} stream: #{opened} of #{limit} used",
            limit: limit, needed: 1
          )
        end

        if direction == :bidi
          @streams_opened_bidi += 1
        else
          @streams_opened_uni += 1
        end
      end

      # "The sum of the lengths of Stream Body data sent on all streams
      # associated with this session MUST NOT exceed the Maximum Data value
      # advertised by a receiver" (§5.6.4). Stream bodies only: the prefix
      # linking a stream to its session is excluded (§5.4).
      def send_data!(bytes)
        return if bytes.zero?

        if @data_sent + bytes > @max_data
          raise WT::SendBlocked.new(
            "cannot send #{bytes} bytes: #{@data_sent} of #{@max_data} used",
            limit: @max_data, needed: bytes
          )
        end

        @data_sent += bytes
      end

      def data_remaining = @max_data - @data_sent

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

    # What a peer is permitted to send us in one session, and what it has used
    # (draft-ietf-webtrans-http3-16 §5.3, §5.4).
    #
    # The mirror of WebTransportFlowControl: that holds limits the peer grants
    # us, this holds limits we granted the peer and enforces them.
    #
    # Limits start at the WT_INITIAL_MAX_* values we advertised and rise as we
    # issue capsules. Counting is deliberately plain integer arithmetic: this
    # runs on every received chunk.
    class WebTransportReceiveLimits
      WT = Protocol::WebTransport

      attr_reader :data_received, :streams_opened_bidi, :streams_opened_uni

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
        @data_received = 0
        @streams_opened_bidi = 0
        @streams_opened_uni = 0
      end

      # "If an endpoint receives an incoming stream for a session that would
      # exceed the advertised Maximum Streams value, it MUST close the
      # WebTransport session with a WT_FLOW_CONTROL_ERROR error code" (§5.6.2).
      #
      # The limit counts closed streams as well as open ones, so this only ever
      # goes up. The CONNECT stream itself is not included (§5.3).
      def open_stream!(direction)
        if direction == :bidi
          @streams_opened_bidi += 1
          exceeded!(:max_streams_bidi, @streams_opened_bidi, @max_streams_bidi)
        else
          @streams_opened_uni += 1
          exceeded!(:max_streams_uni, @streams_opened_uni, @max_streams_uni)
        end
      end

      # "The sum of the lengths of Stream Body data sent on all streams
      # associated with this session MUST NOT exceed the Maximum Data value
      # advertised by a receiver... If an endpoint receives Stream Body data in
      # excess of this limit, it MUST close the WebTransport session with a
      # WT_FLOW_CONTROL_ERROR error code" (§5.6.4).
      #
      # Body only: the signal value, stream type and session ID are excluded so
      # that linking a stream to its session never costs credit (§5.4).
      def receive_data!(bytes)
        return if bytes.zero?

        @data_received += bytes
        exceeded!(:max_data, @data_received, @max_data)
      end

      # A reset stream consumed credit for everything its sender counted, not
      # just what reached us. Without charging the difference the two endpoints
      # disagree about the session total (§5.4, RFC 9000 §4.5).
      def reset_stream!(final_size, delivered)
        return if final_size.nil? || final_size <= delivered

        receive_data!(final_size - delivered)
      end

      private

      def exceeded!(name, used, limit)
        return if used <= limit

        raise WT::FlowControlError, "#{name} exceeded: #{used} of #{limit}"
      end
    end
  end
end
