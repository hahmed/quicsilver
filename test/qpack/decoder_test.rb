# frozen_string_literal: true

require "test_helper"

class QpackDecoderTest < Minitest::Test
  include Quicsilver::Qpack::Decoder

  # decode_qpack_string with H=1 (Huffman)
  def test_decode_huffman_string
    raw = "www.example.com"
    encoded = Quicsilver::Qpack::Encoder.new(huffman: true).send(:encode_str, raw)
    result, consumed = decode_qpack_string(encoded.bytes, 0)

    assert_equal raw, result
    assert_equal encoded.bytesize, consumed
  end

  # decode_qpack_string with H=0 (raw)
  def test_decode_raw_string
    raw = "www.example.com"
    encoded = Quicsilver::Qpack::Encoder.new(huffman: false).send(:encode_str, raw)
    result, consumed = decode_qpack_string(encoded.bytes, 0)

    assert_equal raw, result
    assert_equal encoded.bytesize, consumed
  end

  def test_h_bit_set_for_huffman
    encoded = Quicsilver::Qpack::Encoder.new(huffman: true).send(:encode_str, "www.example.com")
    assert_equal 0x80, encoded.bytes[0] & 0x80, "H bit should be set"
  end

  def test_h_bit_clear_for_raw
    encoded = Quicsilver::Qpack::Encoder.new(huffman: false).send(:encode_str, "www.example.com")
    assert_equal 0x00, encoded.bytes[0] & 0x80, "H bit should be clear"
  end

  def test_decode_empty_string_huffman
    encoded = Quicsilver::Qpack::Encoder.new(huffman: true).send(:encode_str, "")
    result, consumed = decode_qpack_string(encoded.bytes, 0)

    assert_equal "", result
    assert_equal encoded.bytesize, consumed
  end

  def test_decode_empty_string_raw
    encoded = Quicsilver::Qpack::Encoder.new(huffman: false).send(:encode_str, "")
    result, consumed = decode_qpack_string(encoded.bytes, 0)

    assert_equal "", result
    assert_equal encoded.bytesize, consumed
  end

  # Roundtrip: encode with Huffman, decode back
  def test_roundtrip_huffman_typical_headers
    values = ["application/json", "text/html", "GET", "/api/v1/users", "no-cache", "gzip, deflate"]
    encoder = Quicsilver::Qpack::Encoder.new(huffman: true)

    values.each do |val|
      encoded = encoder.send(:encode_str, val)
      result, _consumed = decode_qpack_string(encoded.bytes, 0)
      assert_equal val, result, "Huffman roundtrip failed for #{val.inspect}"
    end
  end

  # Roundtrip: encode without Huffman, decode back
  def test_roundtrip_raw_typical_headers
    values = ["application/json", "text/html", "GET", "/api/v1/users", "no-cache", "gzip, deflate"]
    encoder = Quicsilver::Qpack::Encoder.new(huffman: false)

    values.each do |val|
      encoded = encoder.send(:encode_str, val)
      result, _consumed = decode_qpack_string(encoded.bytes, 0)
      assert_equal val, result, "Raw roundtrip failed for #{val.inspect}"
    end
  end

  # Full QPACK header block: Huffman encoder → request parser
  def test_request_parser_decodes_huffman_headers
    encoder = Quicsilver::Qpack::Encoder.new(huffman: true)
    headers_payload = encoder.encode(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/test",
      "user-agent" => "Quicsilver/1.0"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal "GET", parser.headers[":method"]
    assert_equal "/test", parser.headers[":path"]
    assert_equal "Quicsilver/1.0", parser.headers["user-agent"]
  end

  # Full QPACK header block: raw encoder → request parser
  def test_request_parser_decodes_raw_headers
    encoder = Quicsilver::Qpack::Encoder.new(huffman: false)
    headers_payload = encoder.encode(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost:4433",
      ":path" => "/test",
      "user-agent" => "Quicsilver/1.0"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal "GET", parser.headers[":method"]
    assert_equal "/test", parser.headers[":path"]
    assert_equal "Quicsilver/1.0", parser.headers["user-agent"]
  end

  # Full QPACK header block: raw encoder → response parser
  def test_response_parser_decodes_raw_headers
    encoder = Quicsilver::Qpack::Encoder.new(huffman: false)
    headers_payload = encoder.encode(
      ":status" => "200",
      "content-type" => "text/plain",
      "x-custom" => "raw-value"
    )
    data = build_frame(Quicsilver::HTTP3::FRAME_HEADERS, headers_payload)
    parser = Quicsilver::HTTP3::ResponseParser.new(data)
    parser.parse

    assert_equal 200, parser.status
    assert_equal "text/plain", parser.headers["content-type"]
    assert_equal "raw-value", parser.headers["x-custom"]
  end

  # decode_prefix_integer
  def test_decode_prefix_integer_small
    # Value 10 in 6-bit prefix: single byte 0xC0 | 10 = 0xCA
    result, consumed = decode_prefix_integer([0xCA], 0, 6, 0xC0)
    assert_equal 10, result
    assert_equal 1, consumed
  end

  def test_decode_prefix_integer_large
    # Value 100 with 6-bit prefix: max=63, 100-63=37
    # First byte: 0xFF, second byte: 37
    result, consumed = decode_prefix_integer([0xFF, 37], 0, 6, 0xC0)
    assert_equal 100, result
    assert_equal 2, consumed
  end

  private

  def build_frame(type, payload)
    Quicsilver::HTTP3.encode_varint(type) +
      Quicsilver::HTTP3.encode_varint(payload.bytesize) +
      payload
  end
end
