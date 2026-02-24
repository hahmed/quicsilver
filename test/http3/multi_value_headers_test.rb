# frozen_string_literal: true

require_relative "../http3_test_helper"

class MultiValueHeadersTest < Minitest::Test
  include HTTP3TestHelpers

  def test_request_duplicate_headers_combined_with_comma
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

  def test_response_set_cookie_joined_with_newline
    custom_decoder = Object.new
    def custom_decoder.decode(_payload)
      yield ":status", "200"
      yield "set-cookie", "a=1; Path=/"
      yield "set-cookie", "b=2; HttpOnly"
    end

    frame = build_headers_frame("\x00\x00".b)
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

    frame = build_headers_frame("\x00\x00".b)
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

    frame = build_headers_frame("\x00\x00".b)
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

  def parse_request(payload)
    parser = Quicsilver::HTTP3::RequestParser.new(build_headers_frame(payload))
    parser.parse
    parser
  end
end
