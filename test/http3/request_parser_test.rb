# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/quicsilver/http3"
require_relative "../../lib/quicsilver/http3/request_parser"

class RequestParserTest < Minitest::Test
  def test_parses_headers_and_body
    # GET with custom headers
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/test",
      "user-agent" => "Quicsilver/1.0"
    )
    parser = Quicsilver::HTTP3::RequestParser.new(build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload))
    parser.parse

    assert_equal "GET", parser.headers[":method"]
    assert_equal "/test", parser.headers[":path"]
    assert_equal "Quicsilver/1.0", parser.headers["user-agent"]
    assert_empty parser.body.read

    # POST with body
    headers_payload = build_qpack_headers(
      ":method" => "POST",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/api"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload) + build_frame(Quicsilver::HTTP3::FRAME_DATA, "body content")
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal "POST", parser.headers[":method"]
    assert_equal "body content", parser.body.read
  end

  def test_to_rack_env
    headers_payload = build_qpack_headers(
      ":method" => "POST",
      ":scheme" => "https",
      ":authority" => "example.com:443",
      ":path" => "/search?q=test",
      "content-type" => "application/json"
    )
    body = "test body".b
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload) + build_frame(Quicsilver::HTTP3::FRAME_DATA, body)
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    env = parser.to_rack_env

    assert_equal "POST", env["REQUEST_METHOD"]
    assert_equal "/search", env["PATH_INFO"]
    assert_equal "q=test", env["QUERY_STRING"]
    assert_equal "example.com", env["SERVER_NAME"]
    assert_equal "443", env["SERVER_PORT"]
    assert_equal "HTTP/3", env["SERVER_PROTOCOL"]
    assert_equal "https", env["rack.url_scheme"]
    assert_equal body.bytesize.to_s, env["CONTENT_LENGTH"]
    assert_equal "application/json", env["HTTP_CONTENT_TYPE"]
    assert_equal body, env["rack.input"].read

    # Nil when no headers
    assert_nil Quicsilver::HTTP3::RequestParser.new("").tap(&:parse).to_rack_env
  end

  def test_parse_empty_data
    parser = Quicsilver::HTTP3::RequestParser.new("")
    parser.parse

    assert_empty parser.frames
    assert_empty parser.headers
    assert_empty parser.body.read
  end

  def test_parse_multiple_data_frames
    headers_payload = build_qpack_headers(
      ":method" => "POST",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/upload"
    )

    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_DATA, "chunk1")
    data += build_frame(Quicsilver::HTTP3::FRAME_DATA, "chunk2")
    data += build_frame(Quicsilver::HTTP3::FRAME_DATA, "chunk3")

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal "chunk1chunk2chunk3", parser.body.read
  end

  def test_frames_are_recorded
    headers_payload = build_qpack_headers(
      ":method" => "POST",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/"
    )

    body_data = "test"
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_DATA, body_data)

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal 2, parser.frames.length
    assert_equal Quicsilver::HTTP3::FRAME_HEADERS, parser.frames[0][:type]
    assert_equal Quicsilver::HTTP3::FRAME_DATA, parser.frames[1][:type]
  end

  private

  def build_frame(type, payload)
    frame_type = Quicsilver::HTTP3.encode_varint(type)
    frame_length = Quicsilver::HTTP3.encode_varint(payload.bytesize)
    frame_type + frame_length + payload
  end

  def build_qpack_headers(headers)
    payload = "\x00\x00".b # QPACK prefix

    headers.each do |name, value|
      if name.start_with?(":")
        case name
        when ":method"
          index = value == "GET" ? Quicsilver::HTTP3::QPACK_METHOD_GET : Quicsilver::HTTP3::QPACK_METHOD_POST
          payload += [0x40 | index].pack('C')
        when ":scheme"
          index = value == "https" ? Quicsilver::HTTP3::QPACK_SCHEME_HTTPS : Quicsilver::HTTP3::QPACK_SCHEME_HTTP
          payload += [0x40 | index].pack('C')
        when ":authority"
          payload += [0x40 | Quicsilver::HTTP3::QPACK_AUTHORITY].pack('C')
          payload += Quicsilver::HTTP3.encode_varint(value.bytesize)
          payload += value.b
        when ":path"
          payload += [0x40 | Quicsilver::HTTP3::QPACK_PATH].pack('C')
          payload += Quicsilver::HTTP3.encode_varint(value.bytesize)
          payload += value.b
        else
          payload += encode_literal_header(name, value)
        end
      else
        payload += encode_literal_header(name, value)
      end
    end

    payload
  end

  def encode_literal_header(name, value)
    result = "".b
    result += [0x20 | (name.bytesize & 0x1F)].pack('C')
    result += name.b
    result += Quicsilver::HTTP3.encode_varint(value.bytesize)
    result += value.b
    result
  end
end
