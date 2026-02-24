# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "set"
require "quicsilver/http3"
require "quicsilver/qpack/huffman_code"
require "quicsilver/qpack/decoder"
require "quicsilver/qpack/encoder"
require "quicsilver/qpack/header_block_decoder"
require "quicsilver/http3/request_parser"
require "quicsilver/http3/response_parser"

require "minitest/autorun"

class MultiValueHeadersTest < Minitest::Test
  # === RequestParser: duplicate regular headers combined with comma ===

  def test_request_duplicate_headers_combined_with_comma
    # A client sending two "accept" headers
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":path", "/")
    payload += encode_literal("accept", "text/html")
    payload += encode_literal("accept", "application/json")

    parser = parse_request(payload)

    assert_equal "text/html, application/json", parser.headers["accept"]
  end

  def test_request_cookie_combined_with_semicolon
    # RFC 9114 §4.2.1: cookie headers are combined with "; "
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":path", "/")
    payload += encode_literal("cookie", "a=1")
    payload += encode_literal("cookie", "b=2")

    parser = parse_request(payload)

    assert_equal "a=1; b=2", parser.headers["cookie"]
  end

  def test_request_single_header_unchanged
    payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":path" => "/",
      "accept" => "text/html"
    )
    parser = parse_request(payload)

    assert_equal "text/html", parser.headers["accept"]
  end

  # === ResponseParser: set-cookie uses \n separator (Rack convention) ===

  def test_response_set_cookie_joined_with_newline
    # set-cookie MUST NOT be combined with comma (RFC 9110 §5.3)
    # Rack convention: multiple set-cookie values joined with \n
    custom_decoder = Object.new
    def custom_decoder.decode(_payload)
      yield ":status", "200"
      yield "set-cookie", "a=1; Path=/"
      yield "set-cookie", "b=2; HttpOnly"
    end

    frame = build_frame(0x01, "\x00\x00".b)
    parser = Quicsilver::HTTP3::ResponseParser.new(frame, decoder: custom_decoder)
    parser.parse

    assert_equal "a=1; Path=/\nb=2; HttpOnly", parser.headers["set-cookie"]
  end

  def test_response_duplicate_headers_combined_with_comma
    custom_decoder = Object.new
    def custom_decoder.decode(_payload)
      yield ":status", "200"
      yield "cache-control", "no-cache"
      yield "cache-control", "no-store"
    end

    frame = build_frame(0x01, "\x00\x00".b)
    parser = Quicsilver::HTTP3::ResponseParser.new(frame, decoder: custom_decoder)
    parser.parse

    assert_equal "no-cache, no-store", parser.headers["cache-control"]
  end

  def test_response_single_set_cookie_unchanged
    custom_decoder = Object.new
    def custom_decoder.decode(_payload)
      yield ":status", "200"
      yield "set-cookie", "a=1; Path=/"
    end

    frame = build_frame(0x01, "\x00\x00".b)
    parser = Quicsilver::HTTP3::ResponseParser.new(frame, decoder: custom_decoder)
    parser.parse

    assert_equal "a=1; Path=/", parser.headers["set-cookie"]
  end

  # === to_rack_env passes combined values through correctly ===

  def test_rack_env_receives_combined_cookie
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":authority", "example.com")
    payload += encode_literal(":path", "/")
    payload += encode_literal("cookie", "a=1")
    payload += encode_literal("cookie", "b=2")

    parser = parse_request(payload)
    env = parser.to_rack_env

    assert_equal "a=1; b=2", env["HTTP_COOKIE"]
  end

  def test_rack_env_receives_combined_accept
    payload = qpack_prefix
    payload += encode_literal(":method", "GET")
    payload += encode_literal(":scheme", "https")
    payload += encode_literal(":authority", "example.com")
    payload += encode_literal(":path", "/")
    payload += encode_literal("accept", "text/html")
    payload += encode_literal("accept", "application/json")

    parser = parse_request(payload)
    env = parser.to_rack_env

    assert_equal "text/html, application/json", env["HTTP_ACCEPT"]
  end

  private

  def qpack_prefix
    "\x00\x00".b
  end

  def encode_literal(name, value)
    name_bytes = name.b
    value_bytes = value.b
    out = "".b
    out << encode_prefixed_int(name_bytes.bytesize, 3, 0x20)
    out << name_bytes
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

  def parse_request(payload)
    parser = Quicsilver::HTTP3::RequestParser.new(build_frame(0x01, payload))
    parser.parse
    parser
  end
end
