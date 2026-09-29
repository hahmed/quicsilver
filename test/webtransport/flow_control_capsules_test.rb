# frozen_string_literal: true

require_relative "../test_helper"

# Session flow control capsules (draft-ietf-webtrans-http3-16 §5.6).
#
# These sit above QUIC's own limits: QUIC bounds the connection and each
# stream, these bound one session across all of its streams. This file covers
# the codec only — negotiation, accounting and enforcement are separate.
class WebTransportFlowControlCapsulesTest < Minitest::Test
  WT = Quicsilver::Protocol::WebTransport

  # === registered code points (§9.6) ===

  def test_capsule_types_match_the_registry
    assert_equal 0x190B4D3D, WT::MAX_DATA_CAPSULE
    assert_equal 0x190B4D3F, WT::MAX_STREAMS_BIDI_CAPSULE
    assert_equal 0x190B4D40, WT::MAX_STREAMS_UNI_CAPSULE
    assert_equal 0x190B4D41, WT::DATA_BLOCKED_CAPSULE
    assert_equal 0x190B4D43, WT::STREAMS_BLOCKED_BIDI_CAPSULE
    assert_equal 0x190B4D44, WT::STREAMS_BLOCKED_UNI_CAPSULE
  end

  def test_flow_control_error_matches_the_registry
    assert_equal 0x045d4487, WT::FLOW_CONTROL_ERROR
  end

  def test_recognises_only_the_four_flow_control_capsule_families
    [WT::MAX_DATA_CAPSULE, WT::MAX_STREAMS_BIDI_CAPSULE, WT::MAX_STREAMS_UNI_CAPSULE,
      WT::DATA_BLOCKED_CAPSULE, WT::STREAMS_BLOCKED_BIDI_CAPSULE,
      WT::STREAMS_BLOCKED_UNI_CAPSULE].each do |type|
      assert WT.flow_control_capsule?(type), "0x#{type.to_s(16)} should be flow control"
    end

    [WT::CLOSE_SESSION_CAPSULE, WT::DRAIN_SESSION_CAPSULE, 0x00, 0x190B4D42].each do |type|
      refute WT.flow_control_capsule?(type), "0x#{type.to_s(16)} should not be flow control"
    end
  end

  # === parsing (§5.6.2–5.6.5) ===

  def test_parses_each_capsule_into_its_kind_and_direction
    {
      WT::MAX_DATA_CAPSULE => [:max_data, nil],
      WT::MAX_STREAMS_BIDI_CAPSULE => [:max_streams, :bidi],
      WT::MAX_STREAMS_UNI_CAPSULE => [:max_streams, :uni],
      WT::DATA_BLOCKED_CAPSULE => [:data_blocked, nil],
      WT::STREAMS_BLOCKED_BIDI_CAPSULE => [:streams_blocked, :bidi],
      WT::STREAMS_BLOCKED_UNI_CAPSULE => [:streams_blocked, :uni]
    }.each do |type, (kind, direction)|
      limit = WT.parse_flow_control_capsule(type, varint(1234))

      assert_equal kind, limit.kind
      if direction.nil?
        assert_nil limit.direction, "#{kind} covers the session, not one stream type"
      else
        assert_equal direction, limit.direction
      end
      assert_equal 1234, limit.limit
    end
  end

  def test_distinguishes_limits_from_blocked_signals
    assert WT.parse_flow_control_capsule(WT::MAX_DATA_CAPSULE, varint(1)).max?
    assert WT.parse_flow_control_capsule(WT::MAX_STREAMS_UNI_CAPSULE, varint(1)).max?
    assert WT.parse_flow_control_capsule(WT::DATA_BLOCKED_CAPSULE, varint(1)).blocked?
    assert WT.parse_flow_control_capsule(WT::STREAMS_BLOCKED_BIDI_CAPSULE, varint(1)).blocked?
  end

  # A zero limit is meaningful: it is the default, and it means the peer must
  # send a capsule before anything can be opened or sent (§5.5).
  def test_accepts_a_zero_limit
    assert_equal 0, WT.parse_flow_control_capsule(WT::MAX_DATA_CAPSULE, varint(0)).limit
  end

  def test_parses_limits_across_every_varint_width
    [0, 63, 64, 16_383, 16_384, 1_073_741_823, 1_073_741_824, WT::MAX_STREAMS_LIMIT].each do |value|
      parsed = WT.parse_flow_control_capsule(WT::MAX_STREAMS_BIDI_CAPSULE, varint(value))

      assert_equal value, parsed.limit, "failed for #{value}"
    end
  end

  def test_rejects_a_capsule_type_that_is_not_flow_control
    assert_raises(ArgumentError) do
      WT.parse_flow_control_capsule(WT::CLOSE_SESSION_CAPSULE, varint(1))
    end
  end

  # === malformed payloads ===
  #
  # A payload we cannot read is a malformed message, not a flow control
  # violation, so it must not surface as FLOW_CONTROL_ERROR.

  def test_rejects_an_empty_payload
    error = assert_raises(Quicsilver::Protocol::Capsule::ParseError) do
      WT.parse_flow_control_capsule(WT::MAX_DATA_CAPSULE, "".b)
    end

    assert_match(/truncated/i, error.message)
  end

  def test_rejects_a_truncated_varint
    truncated = varint(16_384).byteslice(0, 2)

    assert_raises(Quicsilver::Protocol::Capsule::ParseError) do
      WT.parse_flow_control_capsule(WT::MAX_DATA_CAPSULE, truncated)
    end
  end

  def test_rejects_trailing_bytes_after_the_limit
    error = assert_raises(Quicsilver::Protocol::Capsule::ParseError) do
      WT.parse_flow_control_capsule(WT::MAX_DATA_CAPSULE, varint(5) + "extra".b)
    end

    assert_match(/trailing/i, error.message)
  end

  # === the 2^60 stream ceiling (§5.6.2, §5.6.3) ===
  #
  # "This value cannot exceed 2^60... Recipients of a capsule with a Maximum
  # Streams value larger than this limit MUST close the WebTransport session
  # with a WT_FLOW_CONTROL_ERROR error code."

  def test_a_stream_limit_above_two_to_the_sixty_is_a_flow_control_error
    [WT::MAX_STREAMS_BIDI_CAPSULE, WT::MAX_STREAMS_UNI_CAPSULE,
      WT::STREAMS_BLOCKED_BIDI_CAPSULE, WT::STREAMS_BLOCKED_UNI_CAPSULE].each do |type|
      error = assert_raises(WT::FlowControlError) do
        WT.parse_flow_control_capsule(type, varint(WT::MAX_STREAMS_LIMIT + 1))
      end

      assert_equal WT::FLOW_CONTROL_ERROR, error.error_code
    end
  end

  def test_exactly_two_to_the_sixty_is_allowed
    parsed = WT.parse_flow_control_capsule(WT::MAX_STREAMS_UNI_CAPSULE, varint(WT::MAX_STREAMS_LIMIT))

    assert_equal WT::MAX_STREAMS_LIMIT, parsed.limit
  end

  # The ceiling exists because a stream count has to map to a stream ID. Data
  # limits are plain byte counts, so they have no such bound.
  def test_a_data_limit_above_two_to_the_sixty_is_allowed
    value = WT::MAX_STREAMS_LIMIT + 1

    assert_equal value, WT.parse_flow_control_capsule(WT::MAX_DATA_CAPSULE, varint(value)).limit
    assert_equal value, WT.parse_flow_control_capsule(WT::DATA_BLOCKED_CAPSULE, varint(value)).limit
  end

  # === building ===

  def test_built_capsules_round_trip_through_the_parser
    {
      WT.build_max_data(4096) => [:max_data, nil, 4096],
      WT.build_data_blocked(4096) => [:data_blocked, nil, 4096],
      WT.build_max_streams(:bidi, 7) => [:max_streams, :bidi, 7],
      WT.build_max_streams(:uni, 8) => [:max_streams, :uni, 8],
      WT.build_streams_blocked(:bidi, 9) => [:streams_blocked, :bidi, 9],
      WT.build_streams_blocked(:uni, 10) => [:streams_blocked, :uni, 10]
    }.each do |wire, (kind, direction, limit)|
      type, payload, remainder = Quicsilver::Protocol::Capsule.parse(wire)
      parsed = WT.parse_flow_control_capsule(type, payload)

      assert_empty remainder
      assert_equal kind, parsed.kind
      if direction.nil?
        assert_nil parsed.direction
      else
        assert_equal direction, parsed.direction
      end
      assert_equal limit, parsed.limit
    end
  end

  def test_builds_the_registered_type_for_each_direction
    assert_equal WT::MAX_STREAMS_BIDI_CAPSULE, capsule_type(WT.build_max_streams(:bidi, 1))
    assert_equal WT::MAX_STREAMS_UNI_CAPSULE, capsule_type(WT.build_max_streams(:uni, 1))
    assert_equal WT::STREAMS_BLOCKED_BIDI_CAPSULE, capsule_type(WT.build_streams_blocked(:bidi, 1))
    assert_equal WT::STREAMS_BLOCKED_UNI_CAPSULE, capsule_type(WT.build_streams_blocked(:uni, 1))
  end

  # Building a capsule the peer would have to reject is our bug, so it raises
  # ArgumentError rather than producing a protocol error on the wire.
  def test_refuses_to_build_a_stream_limit_the_peer_must_reject
    assert_raises(ArgumentError) { WT.build_max_streams(:bidi, WT::MAX_STREAMS_LIMIT + 1) }
    assert_raises(ArgumentError) { WT.build_streams_blocked(:uni, WT::MAX_STREAMS_LIMIT + 1) }
  end

  def test_refuses_to_build_an_unencodable_or_negative_limit
    assert_raises(ArgumentError) { WT.build_max_data(-1) }
    assert_raises(ArgumentError) { WT.build_max_data(WT::VARINT_MAX + 1) }
    assert_raises(ArgumentError) { WT.build_max_data("4096") }
  end

  def test_refuses_an_unknown_direction
    assert_raises(ArgumentError) { WT.build_max_streams(:sideways, 1) }
  end

  # === prohibited capsules (§5.4) ===
  #
  # "The WT_MAX_STREAM_DATA and WT_STREAM_DATA_BLOCKED capsules... are not
  # used and are prohibited. Endpoints MUST treat receipt of a
  # WT_MAX_STREAM_DATA or a WT_STREAM_DATA_BLOCKED capsule as a session
  # error." Over HTTP/3 each WebTransport stream is a QUIC stream, so QUIC
  # already provides per-stream limits.

  def test_prohibited_capsule_types_fill_the_gaps_in_the_registered_block
    assert_equal 0x190B4D3E, WT::MAX_STREAM_DATA_CAPSULE
    assert_equal 0x190B4D42, WT::STREAM_DATA_BLOCKED_CAPSULE
  end

  def test_recognises_the_prohibited_capsules
    assert WT.prohibited_capsule?(WT::MAX_STREAM_DATA_CAPSULE)
    assert WT.prohibited_capsule?(WT::STREAM_DATA_BLOCKED_CAPSULE)
  end

  # §5.6 names only MAX_DATA, MAX_STREAMS, DATA_BLOCKED and STREAMS_BLOCKED as
  # "the flow control capsules", which is what §5.1 says to ignore when flow
  # control is off. The prohibited pair is not in that set.
  def test_prohibited_capsules_are_not_flow_control_capsules
    refute WT.flow_control_capsule?(WT::MAX_STREAM_DATA_CAPSULE)
    refute WT.flow_control_capsule?(WT::STREAM_DATA_BLOCKED_CAPSULE)
  end

  def test_permitted_capsules_are_not_prohibited
    [WT::MAX_DATA_CAPSULE, WT::MAX_STREAMS_BIDI_CAPSULE, WT::DATA_BLOCKED_CAPSULE,
      WT::STREAMS_BLOCKED_UNI_CAPSULE, WT::CLOSE_SESSION_CAPSULE,
      WT::DRAIN_SESSION_CAPSULE].each do |type|
      refute WT.prohibited_capsule?(type), "0x#{type.to_s(16)} should be allowed"
    end
  end

  # === negotiation (§5.1) ===
  #
  # "Flow control is enabled when both endpoints declare their intent to use
  # flow control" by sending a non-zero value for any of the three
  # WT_INITIAL_MAX_* settings. A non-zero value is therefore a promise to
  # implement the whole of §5.

  Frames = Quicsilver::Protocol

  def test_the_three_settings_that_declare_intent
    assert_equal [0x2b61, 0x2b64, 0x2b65].sort, Frames::WT_FLOW_CONTROL_SETTINGS.sort
  end

  def test_any_one_non_zero_setting_declares_intent
    Frames::WT_FLOW_CONTROL_SETTINGS.each do |id|
      assert Frames.wt_flow_control_opt_in?(id => 1), "0x#{id.to_s(16)} should opt in"
    end
  end

  # "0" is the default and means the endpoint needs capsules before anything
  # can be opened or sent (§5.5), so it is not an opt-in.
  def test_zero_or_absent_settings_do_not_declare_intent
    refute Frames.wt_flow_control_opt_in?({})
    refute Frames.wt_flow_control_opt_in?(Frames::WT_FLOW_CONTROL_SETTINGS.to_h { |id| [id, 0] })
    refute Frames.wt_flow_control_opt_in?(Frames::SETTINGS_WT_ENABLED => 1)
  end

  # Advertising a non-zero limit is the promise that the whole of §5 works.
  def test_we_declare_intent_to_use_flow_control
    assert Frames.wt_flow_control_opt_in?(Frames.control_stream_settings)
  end

  # A single child queues 1 MiB, so the session window has to be well above
  # that or one stream could consume the whole session's credit.
  def test_the_session_window_is_larger_than_one_streams_queue
    per_stream = Quicsilver::Server::WebTransportSession::DEFAULT_RECEIVE_OPTIONS[:receive_buffer_bytes]

    assert_operator Frames::WT_INITIAL_MAX_DATA, :>, per_stream * 4
  end

  def test_both_stream_directions_are_advertised
    settings = Frames.control_stream_settings

    assert_operator settings[Frames::SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI], :>, 0
    assert_operator settings[Frames::SETTINGS_WT_INITIAL_MAX_STREAMS_UNI], :>, 0
  end

  # §5.1 permits more than one session once flow control is on, but sharing a
  # connection between sessions is a separate change.
  def test_still_one_session_per_connection
    assert_equal 1, Frames.control_stream_settings[Frames::SETTINGS_WT_MAX_SESSIONS]
  end

  def test_advertised_settings_match_what_the_control_stream_sends
    settings = Frames.control_stream_settings(max_field_section_size: 4096)
    wire = Frames.build_control_stream(max_field_section_size: 4096)

    settings.each do |id, value|
      assert_includes wire, Frames.encode_varint(id) + Frames.encode_varint(value),
        "0x#{id.to_s(16)} missing from the control stream"
    end
  end

  private

  def varint(value) = Quicsilver::Protocol.encode_varint(value)

  def capsule_type(wire) = Quicsilver::Protocol::Capsule.parse(wire).first
end
