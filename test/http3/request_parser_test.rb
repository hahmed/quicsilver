# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/quicsilver/http3"
require_relative "../../lib/quicsilver/http3/request_parser"

class RequestParserTest < Minitest::Test
  def test_parses_get
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
  end

  def test_parses_post_with_body
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
    assert_equal "application/json", env["CONTENT_TYPE"]
    assert_equal body, env["rack.input"].read

  end

  def test_to_rack_env_returns_nil_when_no_headers
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

  def test_indexed_field_with_high_index
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/",
      "upgrade-insecure-requests" => "1"
    )
    parser = Quicsilver::HTTP3::RequestParser.new(build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload))
    parser.parse

    assert_equal "GET", parser.headers[":method"]
    assert_equal "1", parser.headers["upgrade-insecure-requests"]
  end

  def test_literal_with_name_reference_high_index
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/",
      "user-agent" => "TestBot/2.0"
    )
    parser = Quicsilver::HTTP3::RequestParser.new(build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload))
    parser.parse

    assert_equal "TestBot/2.0", parser.headers["user-agent"]
  end

  def test_indexed_field_with_empty_value
    # Static table index 0 is [":authority", ""] — an empty-value entry.
    # Pattern 1 (fully indexed) should still produce {":authority" => ""}
    encoder = Quicsilver::Qpack::Encoder.new
    # Manually build indexed field line for index 0
    indexed_byte = encoder.send(:encode_indexed, 0)
    payload = "\x00\x00".b + indexed_byte
    frame = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, payload)

    parser = Quicsilver::HTTP3::RequestParser.new(frame)
    parser.parse

    assert_equal "", parser.headers[":authority"]
  end

  def test_all_indexed_fields_roundtrip
    encoder = Quicsilver::Qpack::Encoder.new
    table = Quicsilver::HTTP3::STATIC_TABLE

    table.each_with_index do |(name, value), idx|
      next if value.empty? # Skip name-only entries
      next if name.start_with?(":status") # Response-only pseudo-headers

      payload = encoder.encode({ name => value })
      frame = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, payload)
      parser = Quicsilver::HTTP3::RequestParser.new(frame)
      parser.parse

      assert_equal value, parser.headers[name],
        "Static table index #{idx}: #{name}=#{value} failed to roundtrip"
    end
  end

  def test_rejects_settings_frame_on_request_stream
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_SETTINGS, "\x01\x00")

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parser = Quicsilver::HTTP3::RequestParser.new(data)
      parser.parse
    end
  end

  def test_rejects_goaway_frame_on_request_stream
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_GOAWAY, "\x00")

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parser = Quicsilver::HTTP3::RequestParser.new(data)
      parser.parse
    end
  end

  def test_rejects_max_push_id_frame_on_request_stream
    headers_payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_MAX_PUSH_ID, "\x00")

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parser = Quicsilver::HTTP3::RequestParser.new(data)
      parser.parse
    end
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
    Quicsilver::Qpack::Encoder.new.encode(headers)
  end
end
