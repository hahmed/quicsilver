# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/quicsilver/http3"
require_relative "../../lib/quicsilver/http3/response_parser"

class ResponseParserTest < Minitest::Test
  def test_parses_200_response
    headers_payload = build_qpack_response_headers(200, {
      "content-type" => "text/plain"
    })
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_equal 200, parser.status
    assert_equal "text/plain", parser.headers["content-type"]
    assert_empty parser.body.read
  end

  def test_parses_response_with_body
    headers_payload = build_qpack_response_headers(200, {})
    data = build_frame(HEADERS, headers_payload) + build_frame(DATA, "response body")
    parser = parse(data)

    assert_equal 200, parser.status
    assert_equal "response body", parser.body.read
  end

  # Status code handling - indexed field line (pattern 1: 0xC0)
  def test_parses_indexed_status_codes
    # These use fully indexed entries from static table
    [200, 204, 304, 404, 500].each do |status|
      headers_payload = "\x00\x00".b + build_indexed_status(status)
      parser = parse(build_frame(HEADERS, headers_payload))

      assert_equal status, parser.status, "Expected status #{status}"
    end
  end

  def test_parses_non_indexed_status_codes
    # Status codes not in static table use literal with name reference
    [201, 301, 401, 418, 502].each do |status|
      headers_payload = build_qpack_response_headers(status, {})
      parser = parse(build_frame(HEADERS, headers_payload))

      assert_equal status, parser.status, "Expected status #{status}"
    end
  end

  # Header patterns
  def test_parses_literal_with_name_reference
    # content-disposition has a name-only entry in static table (index 3),
    # so the encoder uses Pattern 3 (literal with name reference)
    headers_payload = build_qpack_response_headers(200, {
      "content-disposition" => "attachment"
    })
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_equal "attachment", parser.headers["content-disposition"]
  end

  def test_parses_literal_with_literal_name
    # x-custom-header has no static table entry,
    # so the encoder uses Pattern 5 (fully literal)
    headers_payload = build_qpack_response_headers(200, {
      "x-custom-header" => "custom-value"
    })
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_equal "custom-value", parser.headers["x-custom-header"]
  end

  def test_parses_multiple_headers
    headers_payload = build_qpack_response_headers(200, {
      "content-type" => "application/json",
      "cache-control" => "no-cache",
      "x-request-id" => "abc123"
    })
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_equal "application/json", parser.headers["content-type"]
    assert_equal "no-cache", parser.headers["cache-control"]
    assert_equal "abc123", parser.headers["x-request-id"]
  end

  # Body handling
  def test_parses_empty_body
    headers_payload = build_qpack_response_headers(204, {})
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_empty parser.body.read
  end

  def test_parses_multiple_data_frames
    headers_payload = build_qpack_response_headers(200, {})
    data = build_frame(HEADERS, headers_payload)
    data += build_frame(DATA, "chunk1")
    data += build_frame(DATA, "chunk2")
    data += build_frame(DATA, "chunk3")

    parser = parse(data)

    assert_equal "chunk1chunk2chunk3", parser.body.read
  end

  def test_parses_large_body
    headers_payload = build_qpack_response_headers(200, {})
    large_body = "x" * 10_000
    data = build_frame(HEADERS, headers_payload) + build_frame(DATA, large_body)

    parser = parse(data)

    assert_equal large_body, parser.body.read
  end

  def test_parses_binary_body
    headers_payload = build_qpack_response_headers(200, {})
    binary_data = "\x00\x01\x02\xFF\xFE\xFD".b
    data = build_frame(HEADERS, headers_payload) + build_frame(DATA, binary_data)

    parser = parse(data)

    assert_equal binary_data, parser.body.read.b
  end

  # Frame recording
  def test_frames_are_recorded
    headers_payload = build_qpack_response_headers(200, {})
    data = build_frame(HEADERS, headers_payload)
    data += build_frame(DATA, "body")

    parser = parse(data)

    assert_equal 2, parser.frames.length
    assert_equal HEADERS, parser.frames[0][:type]
    assert_equal DATA, parser.frames[1][:type]
  end

  def test_frame_payloads_are_captured
    headers_payload = build_qpack_response_headers(200, {})
    body_content = "test body"
    data = build_frame(HEADERS, headers_payload) + build_frame(DATA, body_content)

    parser = parse(data)

    assert_equal headers_payload, parser.frames[0][:payload]
    assert_equal body_content, parser.frames[1][:payload]
  end

  def test_indexed_field_with_empty_value
    # Static table index 0 is [":authority", ""] — empty-value entry
    encoder = Quicsilver::Qpack::Encoder.new
    indexed_byte = encoder.send(:encode_indexed, 0)
    headers_payload = "\x00\x00".b + build_indexed_status(200) + indexed_byte
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_equal "", parser.headers[":authority"]
  end

  def test_rejects_settings_frame_on_request_stream
    headers_payload = build_qpack_response_headers(200, {})
    data = build_frame(HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_SETTINGS, "\x01\x00")

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parse(data)
    end
  end

  def test_rejects_goaway_frame_on_request_stream
    headers_payload = build_qpack_response_headers(200, {})
    data = build_frame(HEADERS, headers_payload)
    data += build_frame(Quicsilver::HTTP3::FRAME_GOAWAY, "\x00")

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parse(data)
    end
  end

  def test_rejects_data_before_headers
    data = build_frame(DATA, "body first")
    data += build_frame(HEADERS, build_qpack_response_headers(200, {}))

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parse(data)
    end
  end

  # Edge cases
  def test_parse_empty_data
    parser = parse("")

    assert_empty parser.frames
    assert_empty parser.headers
    assert_nil parser.status
    assert_empty parser.body.read
  end

  def test_parse_truncated_frame_header
    # Only 1 byte - not enough for frame type + length
    parser = parse("\x01")

    assert_empty parser.frames
  end

  def test_parse_truncated_frame_payload
    # Frame header says 100 bytes but only 5 provided
    data = encode_varint(HEADERS) + encode_varint(100) + "short"

    parser = parse(data)

    assert_empty parser.frames
  end

  def test_handles_headers_only_response
    headers_payload = build_qpack_response_headers(204, {
      "x-empty" => "response"
    })
    parser = parse(build_frame(HEADERS, headers_payload))

    assert_equal 204, parser.status
    assert_equal "response", parser.headers["x-empty"]
    assert_empty parser.body.read
  end

  # Prefix integer decoding (RFC 7541)
  def test_decodes_small_prefix_integers
    # Values 0-62 fit in 6 bits (for indexed field pattern)
    (0..62).step(10).each do |value|
      headers_payload = "\x00\x00".b + [0xC0 | value].pack('C')
      parser = Quicsilver::HTTP3::ResponseParser.new(build_frame(HEADERS, headers_payload))
      # Just verify it parses without error
      parser.parse
    end
  end

  def test_decodes_large_prefix_integers
    # Value 63+ requires multi-byte encoding
    # Index 63 = 0xC0 | 0x3F (all prefix bits set), then continuation
    # For index 63: first byte = 0xFF, second byte = 0x00 (63 + 0*128 = 63)
    headers_payload = "\x00\x00".b + "\xFF\x00".b

    parser = Quicsilver::HTTP3::ResponseParser.new(build_frame(HEADERS, headers_payload))
    parser.parse
    # Index 63 maps to static table entry - just verify no crash
    assert_kind_of Quicsilver::HTTP3::ResponseParser, parser
  end

  # Static table coverage
  def test_static_table_entries_are_accessible
    # Verify key static table entries per RFC 9204 Appendix A
    test_cases = [
      [0,  ":authority", ""],
      [1,  ":path", "/"],
      [17, ":method", "GET"],
      [20, ":method", "POST"],
      [23, ":scheme", "https"],
      [25, ":status", "200"],
      [26, ":status", "304"],
      [27, ":status", "404"],
      [64, ":status", "204"],
      [71, ":status", "500"],
      [46, "content-type", "application/json"],
      [53, "content-type", "text/plain"]
    ]

    test_cases.each do |index, expected_name, expected_value|
      entry = Quicsilver::HTTP3::STATIC_TABLE[index]
      assert_equal expected_name, entry[0], "Index #{index} name mismatch"
      assert_equal expected_value, entry[1], "Index #{index} value mismatch"
    end
  end

  def test_static_table_hsts_casing
    assert_equal 'max-age=31536000; includeSubDomains', Quicsilver::HTTP3::STATIC_TABLE[57][1]
    assert_equal 'max-age=31536000; includeSubDomains; preload', Quicsilver::HTTP3::STATIC_TABLE[58][1]
  end

  private

  HEADERS = Quicsilver::HTTP3::FRAME_HEADERS
  DATA = Quicsilver::HTTP3::FRAME_DATA

  def parse(data)
    parser = Quicsilver::HTTP3::ResponseParser.new(data)
    parser.parse
    parser
  end

  def build_frame(type, payload)
    encode_varint(type) + encode_varint(payload.bytesize) + payload
  end

  def encode_varint(value)
    Quicsilver::HTTP3.encode_varint(value)
  end

  def build_qpack_response_headers(status, headers)
    Quicsilver::Qpack::Encoder.new.encode(
      { ":status" => status.to_s }.merge(headers)
    )
  end

  def build_indexed_status(status)
    # For tests that need just a status in the payload (no prefix)
    encoder = Quicsilver::Qpack::Encoder.new
    full = encoder.encode({ ":status" => status.to_s })
    # Strip the 2-byte QPACK prefix
    full[2..]
  end

end
