# frozen_string_literal: true

require_relative "../test_helper"

class PriorityTest < Minitest::Test
  parallelize_me!

  # === Parsing priority header (RFC 9218 §4) ===

  def test_parse_default_priority
    priority = Quicsilver::Protocol::Priority.new
    assert_equal 3, priority.urgency
    refute priority.incremental
  end

  def test_parse_urgency_only
    priority = Quicsilver::Protocol::Priority.parse("u=0")
    assert_equal 0, priority.urgency
    refute priority.incremental
  end

  def test_parse_urgency_and_incremental
    priority = Quicsilver::Protocol::Priority.parse("u=7, i")
    assert_equal 7, priority.urgency
    assert priority.incremental
  end

  def test_parse_incremental_without_urgency
    priority = Quicsilver::Protocol::Priority.parse("i")
    assert_equal 3, priority.urgency  # default
    assert priority.incremental
  end

  def test_parse_explicit_incremental_false
    priority = Quicsilver::Protocol::Priority.parse("u=2, i=?0")
    assert_equal 2, priority.urgency
    refute priority.incremental
  end

  def test_parse_clamps_urgency_to_valid_range
    priority = Quicsilver::Protocol::Priority.parse("u=9")
    assert_equal 7, priority.urgency

    priority = Quicsilver::Protocol::Priority.parse("u=-1")
    assert_equal 0, priority.urgency
  end

  def test_parse_ignores_unknown_parameters
    priority = Quicsilver::Protocol::Priority.parse("u=1, i, x=42, foo=bar")
    assert_equal 1, priority.urgency
    assert priority.incremental
  end

  def test_parse_nil_returns_default
    priority = Quicsilver::Protocol::Priority.parse(nil)
    assert_equal 3, priority.urgency
    refute priority.incremental
  end

  def test_parse_empty_string_returns_default
    priority = Quicsilver::Protocol::Priority.parse("")
    assert_equal 3, priority.urgency
    refute priority.incremental
  end

  # === Request parser extracts priority ===

  def test_request_parser_extracts_priority_header
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost",
      ":path" => "/style.css",
      "priority" => "u=0, i"
    )

    parser = Quicsilver::Protocol::RequestParser.new(build_frame(headers_payload))
    parser.parse

    assert_equal 0, parser.priority.urgency
    assert parser.priority.incremental
  end

  def test_request_parser_default_priority_when_no_header
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost",
      ":path" => "/"
    )

    parser = Quicsilver::Protocol::RequestParser.new(build_frame(headers_payload))
    parser.parse

    assert_equal 3, parser.priority.urgency
    refute parser.priority.incremental
  end

  # === Encoding priority (RFC 9218 §4) ===

  def test_to_s_default_priority
    priority = Quicsilver::Protocol::Priority.new
    assert_equal "u=3", priority.to_s
  end

  def test_to_s_high_urgency
    priority = Quicsilver::Protocol::Priority.new(urgency: 0)
    assert_equal "u=0", priority.to_s
  end

  def test_to_s_incremental
    priority = Quicsilver::Protocol::Priority.new(urgency: 3, incremental: true)
    assert_equal "i", priority.to_s
  end

  def test_to_s_urgency_and_incremental
    priority = Quicsilver::Protocol::Priority.new(urgency: 1, incremental: true)
    assert_equal "u=1, i", priority.to_s
  end

  def test_roundtrip_parse_to_s
    ["u=0", "u=7", "u=1, i", "i", "u=3"].each do |value|
      parsed = Quicsilver::Protocol::Priority.parse(value)
      reparsed = Quicsilver::Protocol::Priority.parse(parsed.to_s)
      assert_equal parsed.urgency, reparsed.urgency, "Roundtrip failed for #{value}"
      assert_equal parsed.incremental, reparsed.incremental, "Roundtrip failed for #{value}"
    end
  end

  private

  def build_qpack_headers(headers)
    Quicsilver::Protocol::Qpack::Encoder.new(huffman: false).encode(headers)
  end

  def build_frame(payload)
    Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::FRAME_HEADERS) +
      Quicsilver::Protocol.encode_varint(payload.bytesize) +
      payload
  end
end
