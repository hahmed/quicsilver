# frozen_string_literal: true

require "test_helper"

class ProtocolCapsuleTest < Minitest::Test
  include HTTP3TestHelpers
  def test_encode_writes_type_length_and_payload
    encoded = Quicsilver::Protocol::Capsule.encode(0x2a, "hello")

    assert_equal Quicsilver::Protocol.encode_varint(0x2a) +
      Quicsilver::Protocol.encode_varint(5) +
      "hello", encoded
  end

  def test_parse_returns_type_payload_and_remainder
    encoded = Quicsilver::Protocol::Capsule.encode(0x2a, "hello") + "rest"

    type, payload, remainder = Quicsilver::Protocol::Capsule.parse(encoded)

    assert_equal 0x2a, type
    assert_equal "hello", payload
    assert_equal "rest", remainder
  end

  def test_parse_accepts_empty_payload
    encoded = Quicsilver::Protocol::Capsule.encode(0x2a, "")

    type, payload, remainder = Quicsilver::Protocol::Capsule.parse(encoded)

    assert_equal 0x2a, type
    assert_equal "".b, payload
    assert_equal "".b, remainder
  end

  def test_parse_returns_nil_for_incomplete_type
    assert_nil Quicsilver::Protocol::Capsule.parse(truncated_two_byte_varint)
  end

  def test_parse_returns_nil_for_incomplete_length
    encoded = Quicsilver::Protocol.encode_varint(0x2a) + truncated_two_byte_varint

    assert_nil Quicsilver::Protocol::Capsule.parse(encoded)
  end

  def test_parse_returns_nil_for_incomplete_payload
    encoded = Quicsilver::Protocol.encode_varint(0x2a) +
      Quicsilver::Protocol.encode_varint(5) +
      "he"

    assert_nil Quicsilver::Protocol::Capsule.parse(encoded)
  end
end
