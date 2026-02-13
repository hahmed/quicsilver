# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/quicsilver/http3"
require_relative "../../lib/quicsilver/http3/request_encoder"
require_relative "../../lib/quicsilver/http3/request_parser"

class RequestEncoderTest < Minitest::Test
  # Core functionality tests
  def test_encode_get_request
    data = encoder("GET", "/test").encode

    assert_encoded_header(data, ":method", "GET")
    assert_encoded_header(data, ":path", "/test")
    assert_encoded_header(data, ":scheme", "https")
    assert_encoded_header(data, ":authority", "localhost:4433")
    assert_empty parse_body(data)
  end

  def test_encode_post_request_with_body
    body = "test body content"
    data = encoder("POST", "/api/submit", body: body).encode

    assert_encoded_header(data, ":method", "POST")
    assert_encoded_header(data, ":path", "/api/submit")
    assert_equal body, parse_body(data)
  end

  def test_encode_with_custom_headers
    data = encoder("GET", "/", headers: {
      "user-agent" => "Quicsilver/1.0",
      "accept" => "application/json"
    }).encode

    assert_encoded_header(data, "user-agent", "Quicsilver/1.0")
    assert_encoded_header(data, "accept", "application/json")
  end

  def test_encode_method_is_uppercase
    data = encoder("get", "/").encode
    assert_encoded_header(data, ":method", "GET")
  end

  def test_encode_all_http_methods
    %w[GET POST PUT DELETE HEAD OPTIONS CONNECT].each do |method|
      data = encoder(method, "/").encode
      assert_encoded_header(data, ":method", method)
    end
  end

  def test_encode_non_standard_method
    data = encoder("PATCH", "/").encode
    assert_encoded_header(data, ":method", "PATCH")
  end

  def test_encode_http_scheme
    data = encoder("GET", "/", scheme: "http").encode
    assert_encoded_header(data, ":scheme", "http")
  end

  def test_encode_https_scheme
    data = encoder("GET", "/", scheme: "https").encode
    assert_encoded_header(data, ":scheme", "https")
  end

  def test_encode_path_with_query_string
    data = encoder("GET", "/search?q=test&limit=10").encode
    assert_encoded_header(data, ":path", "/search?q=test&limit=10")
  end

  def test_encode_path_with_special_characters
    data = encoder("GET", "/path/with spaces/and%20encoded").encode
    assert_encoded_header(data, ":path", "/path/with spaces/and%20encoded")
  end

  def test_encode_empty_body_no_data_frame
    data = encoder("GET", "/", body: "").encode
    assert_empty parse_body(data)
  end

  def test_encode_nil_body_no_data_frame
    data = encoder("GET", "/", body: nil).encode
    assert_empty parse_body(data)
  end

  def test_encode_array_body_joins_chunks
    data = encoder("POST", "/", body: ["chunk1", "chunk2", "chunk3"]).encode
    assert_equal "chunk1chunk2chunk3", parse_body(data)
  end

  def test_encode_large_body
    large_body = "x" * 10_000
    data = encoder("POST", "/upload", body: large_body).encode
    assert_equal large_body, parse_body(data)
  end

  def test_encode_headers_are_downcased
    data = encoder("GET", "/", headers: {
      "Content-Type" => "application/json",
      "X-Custom-Header" => "value"
    }).encode

    assert_encoded_header(data, "content-type", "application/json")
    assert_encoded_header(data, "x-custom-header", "value")
  end

  def test_encode_produces_binary_string
    data = encoder("GET", "/").encode
    assert_equal Encoding::BINARY, data.encoding
  end

  def test_encode_produces_non_empty_data
    data = encoder("GET", "/").encode
    refute_empty data
    assert_instance_of String, data
  end

  def test_uses_indexed_field_for_common_methods
    # GET and POST should use 0x80 | index (indexed field line)
    data = encoder("GET", "/").encode
    bytes = data.bytes

    # Skip frame header and QPACK prefix, first header byte should be 0xC0 | 17
    # Pattern 0xC0 = indexed field line with static table (T=1 per RFC 9204)
    qpack_start = find_qpack_start(bytes)
    assert qpack_start, "Could not find QPACK prefix"

    first_header_byte = bytes[qpack_start + 2]
    assert_equal 0xC0 | Quicsilver::HTTP3::QPACK_METHOD_GET, first_header_byte,
      "Should use indexed field line (0xC0 | index) for :method GET"
  end

  def test_uses_literal_with_name_ref_for_authority
    # :authority should use 01NTxxxx (N=0, T=1 static, 4-bit index)
    # :authority is index 0, so byte = 0x50 | 0 = 0x50
    data = encoder("GET", "/").encode
    bytes = data.bytes

    qpack_start = find_qpack_start(bytes)
    assert bytes[qpack_start, 20].include?(0x50 | Quicsilver::HTTP3::QPACK_AUTHORITY),
      "Should use literal with name ref (0x50 | index) for :authority"
  end

  def test_connect_omits_scheme_and_path
    data = encoder("CONNECT", "/", authority: "proxy.example.com:443").encode
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal "CONNECT", parser.headers[":method"]
    assert_equal "proxy.example.com:443", parser.headers[":authority"]
    assert_nil parser.headers[":scheme"]
    assert_nil parser.headers[":path"]
  end

  # Roundtrip tests
  def test_roundtrip_get_request
    data = encoder("GET", "/test", headers: { "user-agent" => "Test/1.0" }).encode

    assert_encoded_header(data, ":method", "GET")
    assert_encoded_header(data, ":path", "/test")
    assert_encoded_header(data, "user-agent", "Test/1.0")
  end

  def test_roundtrip_post_with_body_and_headers
    data = encoder("POST", "/api/test",
      headers: { "content-type" => "text/plain" },
      body: "test content"
    ).encode

    assert_encoded_header(data, ":method", "POST")
    assert_encoded_header(data, ":path", "/api/test")
    assert_encoded_header(data, "content-type", "text/plain")
    assert_equal "test content", parse_body(data)
  end

  private

  def encoder(method, path, scheme: "https", authority: "localhost:4433", headers: {}, body: nil)
    Quicsilver::HTTP3::RequestEncoder.new(
      method: method,
      path: path,
      scheme: scheme,
      authority: authority,
      headers: headers,
      body: body
    )
  end

  def assert_encoded_header(data, name, value)
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse
    assert_equal value, parser.headers[name], "Expected header #{name} to be #{value}"
  end

  def parse_body(data)
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse
    parser.body.read
  end

  def find_qpack_start(bytes)
    # Find HEADERS frame (type 0x01) and skip to payload
    offset = 0
    while offset < bytes.size - 2
      type, type_len = Quicsilver::HTTP3.decode_varint(bytes, offset)
      return nil if type_len == 0

      length, length_len = Quicsilver::HTTP3.decode_varint(bytes, offset + type_len)
      return nil if length_len == 0

      if type == Quicsilver::HTTP3::FRAME_HEADERS
        return offset + type_len + length_len
      end

      offset += type_len + length_len + length
    end
    nil
  end
end
