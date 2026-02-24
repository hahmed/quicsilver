# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "set"
require "quicsilver/http3"
require "quicsilver/qpack/huffman_code"
require "quicsilver/qpack/decoder"
require "quicsilver/qpack/encoder"
require "quicsilver/http3/request_parser"

require "minitest/autorun"

class PseudoHeaderValidationTest < Minitest::Test
  # === RFC 9114 §4.3.1: Pseudo-header ordering ===

  def test_rejects_pseudo_header_after_regular_header
    # Manually build: regular header "host" then pseudo-header ":path"
    # Can't use Encoder for this since it would order them correctly
    payload = qpack_prefix
    payload += encode_literal("host", "example.com")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  # === RFC 9114 §4.3.1: Duplicate pseudo-headers ===

  def test_rejects_duplicate_method
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":method", "POST")

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  def test_rejects_duplicate_path
    payload = qpack_prefix
    payload += encode_literal(":path", "/")
    payload += encode_literal(":path", "/other")

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  def test_rejects_duplicate_scheme
    payload = qpack_prefix
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":scheme", "http")

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  # === RFC 9114 §4.3.1: Unknown pseudo-headers ===

  def test_rejects_unknown_pseudo_header
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":bogus", "value")

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  # === RFC 9114 §4.2: Header names MUST be lowercase ===

  def test_rejects_uppercase_header_name
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal("Content-Type", "text/plain")

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  # === RFC 9114 §4.3.1: CONNECT method rules ===

  def test_validate_connect_rejects_scheme
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "proxy.example.com:443",
      ":scheme" => "https"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_connect_rejects_path
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "proxy.example.com:443",
      ":path" => "/"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_connect_requires_authority
    # Build manually — CONNECT with only :method, no :authority
    payload = qpack_prefix
    payload += encode_literal(":method", "CONNECT")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_connect_valid
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "proxy.example.com:443"
    )
    parser = parse_headers_frame(headers)
    parser.parse
    # Should not raise
    parser.validate_headers!
  end

  # === RFC 9114 §4.3.1: Non-CONNECT required pseudo-headers ===

  def test_validate_requires_method
    payload = qpack_prefix
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_requires_scheme
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_requires_path
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  # === RFC 9114 §4.3.1: Host / :authority consistency ===

  def test_validate_rejects_inconsistent_host_and_authority
    headers = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "example.com",
      ":path" => "/",
      "host" => "other.com"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_accepts_consistent_host_and_authority
    headers = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "example.com",
      ":path" => "/",
      "host" => "example.com"
    )
    parser = parse_headers_frame(headers)
    parser.parse
    # Should not raise
    parser.validate_headers!
  end

  # === to_rack_env with CONNECT ===

  def test_to_rack_env_connect_request
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "proxy.example.com:443"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    env = parser.to_rack_env
    assert_equal "CONNECT", env["REQUEST_METHOD"]
    assert_equal "proxy.example.com", env["SERVER_NAME"]
    assert_equal "443", env["SERVER_PORT"]
  end

  # === Valid requests still work ===

  def test_valid_get_request_parses_normally
    headers = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "example.com:443",
      ":path" => "/test",
      "user-agent" => "test/1.0"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    # No error from validate
    parser.validate_headers!

    assert_equal "GET", parser.headers[":method"]
    assert_equal "/test", parser.headers[":path"]
  end

  private

  def qpack_prefix
    "\x00\x00".b
  end

  # Encode a literal header field with literal name (pattern 5: 001xxxxx)
  # This bypasses the encoder to produce invalid sequences for testing
  def encode_literal(name, value)
    name_bytes = name.b
    value_bytes = value.b

    out = "".b
    # 001 H=0 N=0 + name length (3-bit prefix, pattern 0x20)
    out << encode_prefixed_int(name_bytes.bytesize, 3, 0x20)
    out << name_bytes
    # H=0 + value length (7-bit prefix, pattern 0x00)
    out << encode_prefixed_int(value_bytes.bytesize, 7, 0x00)
    out << value_bytes
    out
  end

  def encode_prefixed_int(value, prefix_bits, pattern)
    max_prefix = (1 << prefix_bits) - 1
    if value < max_prefix
      [pattern | value].pack("C")
    else
      out = [pattern | max_prefix].pack("C")
      value -= max_prefix
      while value >= 128
        out << [(value & 0x7F) | 0x80].pack("C")
        value >>= 7
      end
      out << [value].pack("C")
      out
    end
  end

  def build_frame(type, payload)
    Quicsilver::HTTP3.encode_varint(type) +
      Quicsilver::HTTP3.encode_varint(payload.bytesize) +
      payload
  end

  def build_qpack_headers(headers)
    Quicsilver::Qpack::Encoder.new(huffman: false).encode(headers)
  end

  def parse_headers_frame(payload)
    Quicsilver::HTTP3::RequestParser.new(build_frame(Quicsilver::HTTP3::FRAME_HEADERS, payload))
  end
end
