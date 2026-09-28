# frozen_string_literal: true

require_relative "../test_helper"

# Session flow control state (draft-ietf-webtrans-http3-16 §5).
#
# Two directions with different rules: limits a peer grants us, which must
# increase and are never spent here, and limits we advertised to the peer,
# which are spent and never move on their own.
class WebTransportFlowControlStateTest < Minitest::Test
  FlowControl = Quicsilver::Server::WebTransportFlowControl
  WT = Quicsilver::Protocol::WebTransport
  Limits = Quicsilver::Server::WebTransportReceiveLimits

  # === initial limits come from SETTINGS (§5.5) ===

  # "The default value ... is 0, indicating that the endpoint needs to send
  # [capsules]" before anything can be opened or sent.
  def test_limits_default_to_zero
    state = FlowControl.new

    assert_equal 0, state.max_data
    assert_equal 0, state.max_streams(:bidi)
    assert_equal 0, state.max_streams(:uni)
  end

  def test_seeds_limits_from_peer_settings
    state = FlowControl.from_settings(
      Quicsilver::Protocol::SETTINGS_WT_INITIAL_MAX_DATA => 4096,
      Quicsilver::Protocol::SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI => 3,
      Quicsilver::Protocol::SETTINGS_WT_INITIAL_MAX_STREAMS_UNI => 5
    )

    assert_equal 4096, state.max_data
    assert_equal 3, state.max_streams(:bidi)
    assert_equal 5, state.max_streams(:uni)
  end

  def test_absent_settings_seed_zero
    state = FlowControl.from_settings({})

    assert_equal 0, state.max_data
    assert_equal 0, state.max_streams(:bidi)
  end

  # === raising limits ===

  def test_max_data_raises_the_data_limit
    state = FlowControl.new

    state.apply(limit(:max_data, nil, 4096))

    assert_equal 4096, state.max_data
  end

  def test_max_streams_raises_each_direction_independently
    state = FlowControl.new

    state.apply(limit(:max_streams, :bidi, 7))

    assert_equal 7, state.max_streams(:bidi)
    assert_equal 0, state.max_streams(:uni), "bidi grant must not move the uni limit"
  end

  def test_limits_accumulate_across_capsules
    state = FlowControl.new
    [1, 2, 100, 1000].each { |value| state.apply(limit(:max_streams, :uni, value)) }

    assert_equal 1000, state.max_streams(:uni)
  end

  # === monotonicity (§5.6.2, §5.6.4) ===
  #
  # "Unlike in QUIC, where MAX_DATA frames can be delivered in any order,
  # WT_MAX_DATA capsules are sent on the WebTransport session's connect stream
  # and are delivered in order. If an endpoint receives a WT_MAX_DATA capsule
  # with a Maximum Data value that does not increase the Maximum Data value
  # previously received, it MUST close the WebTransport session with a
  # WT_FLOW_CONTROL_ERROR error code."

  def test_a_decreasing_data_limit_is_a_flow_control_error
    state = FlowControl.new
    state.apply(limit(:max_data, nil, 4096))

    error = assert_raises(WT::FlowControlError) { state.apply(limit(:max_data, nil, 2048)) }

    assert_equal WT::FLOW_CONTROL_ERROR, error.error_code
    assert_equal 4096, state.max_data, "a rejected capsule must not move the limit"
  end

  # Equal is not an increase.
  def test_a_repeated_data_limit_is_a_flow_control_error
    state = FlowControl.new
    state.apply(limit(:max_data, nil, 4096))

    assert_raises(WT::FlowControlError) { state.apply(limit(:max_data, nil, 4096)) }
  end

  def test_a_non_increasing_stream_limit_is_a_flow_control_error
    %i[bidi uni].each do |direction|
      state = FlowControl.new
      state.apply(limit(:max_streams, direction, 5))

      assert_raises(WT::FlowControlError) { state.apply(limit(:max_streams, direction, 5)) }
      assert_raises(WT::FlowControlError) { state.apply(limit(:max_streams, direction, 4)) }
      assert_equal 5, state.max_streams(direction)
    end
  end

  # The two directions carry separate limits, so the same value on the other
  # direction is a genuine first grant rather than a repeat.
  def test_the_same_value_in_the_other_direction_is_still_an_increase
    state = FlowControl.new
    state.apply(limit(:max_streams, :bidi, 5))

    state.apply(limit(:max_streams, :uni, 5))

    assert_equal 5, state.max_streams(:uni)
  end

  # A zero first grant does not increase the zero default.
  def test_a_zero_limit_is_never_an_increase
    assert_raises(WT::FlowControlError) { FlowControl.new.apply(limit(:max_data, nil, 0)) }
  end

  # === blocked capsules (§5.6.3, §5.6.5) ===
  #
  # "A WT_STREAMS_BLOCKED capsule does not open the stream, but informs the
  # peer that a new stream was needed and the stream limit prevented" it.
  # They report, they do not grant, so they are exempt from monotonicity.

  def test_blocked_capsules_do_not_change_limits
    state = FlowControl.new
    state.apply(limit(:max_data, nil, 4096))

    state.apply(limit(:data_blocked, nil, 4096))
    state.apply(limit(:streams_blocked, :bidi, 0))

    assert_equal 4096, state.max_data
    assert_equal 0, state.max_streams(:bidi)
  end

  def test_a_repeated_blocked_capsule_is_not_an_error
    state = FlowControl.new

    3.times { state.apply(limit(:data_blocked, nil, 0)) }
  end

  # === limits we advertised to the peer (§5.3, §5.4) ===

  def test_seeds_from_the_settings_we_advertised
    limits = Limits.from_settings(
      Quicsilver::Protocol::SETTINGS_WT_INITIAL_MAX_DATA => 100,
      Quicsilver::Protocol::SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI => 2
    )

    limits.receive_data!(100)
    2.times { limits.open_stream!(:bidi) }

    assert_raises(WT::FlowControlError) { limits.receive_data!(1) }
  end

  # === stream counts (§5.6.2) ===

  def test_streams_up_to_the_limit_are_allowed
    limits = Limits.new(max_streams_uni: 3)

    3.times { limits.open_stream!(:uni) }

    assert_equal 3, limits.streams_opened_uni
  end

  def test_one_stream_past_the_limit_is_a_flow_control_error
    limits = Limits.new(max_streams_uni: 3)
    3.times { limits.open_stream!(:uni) }

    error = assert_raises(WT::FlowControlError) { limits.open_stream!(:uni) }

    assert_equal WT::FLOW_CONTROL_ERROR, error.error_code
  end

  def test_the_two_directions_are_counted_separately
    limits = Limits.new(max_streams_bidi: 1, max_streams_uni: 1)

    limits.open_stream!(:bidi)
    limits.open_stream!(:uni)

    assert_raises(WT::FlowControlError) { limits.open_stream!(:bidi) }
  end

  # "Note that this limit includes streams that have been closed as well as
  # those that are open." Nothing gives credit back.
  def test_the_count_never_decreases
    limits = Limits.new(max_streams_bidi: 1)
    limits.open_stream!(:bidi)

    assert_raises(WT::FlowControlError) { limits.open_stream!(:bidi) }
    assert_raises(WT::FlowControlError) { limits.open_stream!(:bidi) }
  end

  # A zero limit is the default and forbids every stream until a capsule
  # raises it (§5.5).
  def test_a_zero_limit_admits_no_streams
    assert_raises(WT::FlowControlError) { Limits.new.open_stream!(:uni) }
  end

  # === data (§5.6.4) ===

  def test_data_up_to_the_limit_is_allowed
    limits = Limits.new(max_data: 100)

    limits.receive_data!(60)
    limits.receive_data!(40)

    assert_equal 100, limits.data_received
  end

  def test_one_byte_past_the_limit_is_a_flow_control_error
    limits = Limits.new(max_data: 100)
    limits.receive_data!(100)

    error = assert_raises(WT::FlowControlError) { limits.receive_data!(1) }

    assert_equal WT::FLOW_CONTROL_ERROR, error.error_code
  end

  def test_empty_chunks_cost_nothing
    limits = Limits.new(max_data: 0)

    limits.receive_data!(0)

    assert_equal 0, limits.data_received
  end

  # === reset streams (§5.4) ===
  #
  # "For streams that were reset, implementing WT_MAX_DATA requires that the
  # QUIC stack provide the WebTransport implementation with information about
  # the final size of streams... This guarantees that both endpoints agree on
  # how much WebTransport session flow control credit was consumed."

  def test_a_reset_charges_the_bytes_that_never_arrived
    limits = Limits.new(max_data: 100)
    limits.receive_data!(10)

    limits.reset_stream!(50, 10)

    assert_equal 50, limits.data_received
  end

  def test_a_reset_past_the_limit_is_a_flow_control_error
    limits = Limits.new(max_data: 100)
    limits.receive_data!(10)

    assert_raises(WT::FlowControlError) { limits.reset_stream!(200, 10) }
  end

  def test_a_reset_charges_nothing_when_everything_arrived
    limits = Limits.new(max_data: 100)
    limits.receive_data!(50)

    limits.reset_stream!(50, 50)

    assert_equal 50, limits.data_received
  end

  # MsQuic reports no final size until one is settled, and a stream can be
  # reset before that. Guessing would diverge from the sender's count.
  def test_an_unknown_final_size_charges_nothing
    limits = Limits.new(max_data: 100)
    limits.receive_data!(10)

    limits.reset_stream!(nil, 10)

    assert_equal 10, limits.data_received
  end

  # Defensive: a final size below what we already took would refund credit.
  def test_a_final_size_below_what_arrived_charges_nothing
    limits = Limits.new(max_data: 100)
    limits.receive_data!(50)

    limits.reset_stream!(20, 50)

    assert_equal 50, limits.data_received
  end

  private

  def limit(kind, direction, value)
    WT::Limit.new(kind: kind, direction: direction, limit: value)
  end
end
