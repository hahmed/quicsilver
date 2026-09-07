# frozen_string_literal: true

require_relative "../test_helper"

# Wire format for WebTransport streams (draft-ietf-webtrans-http3):
#
#   bidi: [type = 0x41 varint][session_id varint][data...]
#   uni:  [session_id varint][data...]        Connection strips the 0x54 type
class WebTransportStreamPrefixTest < Minitest::Test
  parallelize_me!

  Session = Quicsilver::Server::WebTransportSession
  BIDI = Quicsilver::Protocol::WebTransport::BIDI_STREAM_TYPE
  UNI = Quicsilver::Protocol::WebTransport::UNI_STREAM_TYPE

  def test_parses_session_id_and_remainder
    session_id, remainder = Session.parse_stream_prefix(bidi_prefix(0) + "hello")

    assert_equal 0, session_id
    assert_equal "hello", remainder
  end

  def test_parses_a_prefix_with_no_data
    session_id, remainder = Session.parse_stream_prefix(bidi_prefix(0))

    assert_equal 0, session_id
    assert_equal "", remainder
  end

  def test_parses_session_ids_across_every_varint_width
    # Session ids are CONNECT stream ids, so every value here is divisible by
    # 4 — the largest valid id in each varint width rather than the largest
    # encodable one.
    {
      0 => "1-byte, minimum",
      60 => "1-byte, maximum",
      64 => "2-byte, minimum",
      16_380 => "2-byte, maximum",
      16_384 => "4-byte, minimum",
      1_073_741_820 => "4-byte, maximum",
      1_073_741_824 => "8-byte, minimum"
    }.each do |id, width|
      session_id, remainder = Session.parse_stream_prefix(bidi_prefix(id) + "x")

      assert_equal id, session_id, "failed for #{width}"
      assert_equal "x", remainder, "failed for #{width}"
    end
  end

  # Must stay ASCII-8BIT. Tagged UTF-8 it would compare equal for ASCII content
  # while #length, slicing and regexes misread multi-byte sequences.
  def test_keeps_the_payload_binary
    payload = "\x00\xFF\x41\x54".b
    _session_id, remainder = Session.parse_stream_prefix(bidi_prefix(4) + payload)

    assert_equal payload, remainder
    assert_equal Encoding::ASCII_8BIT, remainder.encoding
  end

  # 0x54 is a valid WebTransport type, just not this one. Fails if the bidi and
  # uni paths are ever merged.
  def test_rejects_a_unidirectional_stream_type
    assert_nil Session.parse_stream_prefix(varint(UNI) + varint(0))
  end

  def test_rejects_an_http3_data_frame
    assert_nil Session.parse_stream_prefix("\x00\x05hello".b)
  end

  def test_rejects_an_http3_headers_frame
    assert_nil Session.parse_stream_prefix("\x01\x05hello".b)
  end

  def test_rejects_empty_input
    assert_nil Session.parse_stream_prefix("".b)
  end

  def test_rejects_a_type_byte_with_no_session_id
    assert_nil Session.parse_stream_prefix(varint(BIDI))
  end

  def test_rejects_a_truncated_four_byte_session_id
    full = bidi_prefix(16_384)

    assert_nil Session.parse_stream_prefix(full.byteslice(0, full.bytesize - 1))
  end

  def test_rejects_a_truncated_eight_byte_session_id
    full = bidi_prefix(1_073_741_824)

    assert_nil Session.parse_stream_prefix(full.byteslice(0, 3))
  end

  # === session id validity (§4) ===
  #
  # Session ids are CONNECT stream ids, so id % 4 == 0 always holds.

  def test_rejects_a_bidi_session_id_not_divisible_by_four
    assert_nil Session.parse_stream_prefix(bidi_prefix(7) + "d")
  end

  def test_rejects_a_uni_session_id_not_divisible_by_four
    assert_nil Session.parse_uni_stream_data(varint(7) + "d")
  end

  # === extended CONNECT :protocol (§3.2) ===
  #
  # draft-16 requires "webtransport-h3". The bare "webtransport" token is the
  # capsule-based HTTP/2 binding (§2.1.2) and what pre-15 drafts used over
  # HTTP/3; Chrome still sends it, so both are accepted.

  def test_accepts_the_draft_16_protocol_token
    assert Quicsilver::Protocol::WebTransport.protocol?("webtransport-h3")
  end

  def test_accepts_the_legacy_protocol_token
    assert Quicsilver::Protocol::WebTransport.protocol?("webtransport")
  end

  def test_rejects_other_protocol_tokens
    refute Quicsilver::Protocol::WebTransport.protocol?("websocket")
    refute Quicsilver::Protocol::WebTransport.protocol?(nil)
    refute Quicsilver::Protocol::WebTransport.protocol?("")
  end

  def test_parses_uni_session_id_and_data
    session_id, data = Session.parse_uni_stream_data(varint(4) + "body")

    assert_equal 4, session_id
    assert_equal "body", data
  end

  def test_parses_a_uni_prefix_with_no_data
    session_id, data = Session.parse_uni_stream_data(varint(4))

    assert_equal 4, session_id
    assert_equal "", data
  end

  # Must not decode as session 0, which is a real id — a session established on
  # the first client bidi stream has exactly that id. The bidi method never
  # faces this because its type check rejects empty input first.
  def test_rejects_an_empty_uni_payload
    assert_nil Session.parse_uni_stream_data("".b)
  end

  private

  def varint(value)
    Quicsilver::Protocol.encode_varint(value)
  end

  def bidi_prefix(session_id)
    varint(BIDI) + varint(session_id)
  end
end
