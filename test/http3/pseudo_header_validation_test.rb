# frozen_string_literal: true

require_relative "../http3_test_helper"

class PseudoHeaderValidationTest < Minitest::Test
  parallelize_me!
  include HTTP3TestHelpers

  # === RFC 9114 §4.3.1: Pseudo-header ordering ===

  def test_rejects_pseudo_header_after_regular_header
    payload = qpack_prefix
    payload += encode_literal("host", "example.com")
    payload += encode_literal(":path", "/")

    assert_raises(Quicsilver::Protocol::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  # === RFC 9114 §4.3.1: Duplicate pseudo-headers ===

  def test_rejects_duplicate_method
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":method", "POST")

    assert_raises(Quicsilver::Protocol::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  def test_rejects_duplicate_path
    payload = qpack_prefix
    payload += encode_literal(":path", "/")
    payload += encode_literal(":path", "/other")

    assert_raises(Quicsilver::Protocol::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  def test_rejects_duplicate_scheme
    payload = qpack_prefix
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":scheme", "http")

    assert_raises(Quicsilver::Protocol::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  # === RFC 9114 §4.3.1: Unknown pseudo-headers ===

  def test_rejects_unknown_pseudo_header
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":bogus", "value")

    assert_raises(Quicsilver::Protocol::MessageError) do
      parse_headers_frame(payload).parse
    end
  end

  # === RFC 9114 §4.2: Header names MUST be lowercase ===

  def test_rejects_uppercase_header_name
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal("Content-Type", "text/plain")

    assert_raises(Quicsilver::Protocol::MessageError) do
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

    assert_raises(Quicsilver::Protocol::MessageError) do
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

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_connect_requires_authority
    payload = qpack_prefix
    payload += encode_literal(":method", "CONNECT")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
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
    parser.validate_headers!
  end

  # === RFC 9220: Extended CONNECT ===

  def test_validate_extended_connect_valid
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "example.com",
      ":scheme" => "https",
      ":path" => "/cable",
      ":protocol" => "websocket"
    )
    parser = parse_headers_frame(headers)
    parser.parse
    parser.validate_headers!
  end

  def test_validate_extended_connect_requires_scheme
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "example.com",
      ":path" => "/cable",
      ":protocol" => "websocket"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_extended_connect_requires_path
    headers = build_qpack_headers(
      ":method" => "CONNECT",
      ":authority" => "example.com",
      ":scheme" => "https",
      ":protocol" => "websocket"
    )
    parser = parse_headers_frame(headers)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  # === RFC 9114 §4.3.1: Non-CONNECT required pseudo-headers ===

  def test_validate_requires_method
    payload = qpack_prefix
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_requires_scheme
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_requires_path
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  # === RFC 9114 §4.3.1: http/https schemes require :authority or host ===

  def test_validate_rejects_http_scheme_without_authority_or_host
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_validate_accepts_http_scheme_with_host_only
    headers = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":path" => "/",
      "host" => "example.com"
    )
    parser = parse_headers_frame(headers)
    parser.parse
    parser.validate_headers!
  end

  def test_validate_accepts_custom_scheme_without_authority
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "coap")
    payload += encode_literal(":path", "/")

    parser = parse_headers_frame(payload)
    parser.parse
    parser.validate_headers!
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

    assert_raises(Quicsilver::Protocol::MessageError) do
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
    parser.validate_headers!

    assert_equal "GET", parser.headers[":method"]
    assert_equal "/test", parser.headers[":path"]
  end

  private

  def parse_headers_frame(payload)
    Quicsilver::Protocol::RequestParser.new(build_headers_frame(payload))
  end
end
