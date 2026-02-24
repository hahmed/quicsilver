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

class HeaderBlockDecoderTest < Minitest::Test
  # === Decoder class exists and works standalone ===

  def test_decode_yields_name_value_pairs
    payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":path" => "/test"
    )

    pairs = []
    decoder = Quicsilver::Qpack::HeaderBlockDecoder.new
    decoder.decode(payload) { |name, value| pairs << [name, value] }

    assert_includes pairs, [":method", "GET"]
    assert_includes pairs, [":scheme", "https"]
    assert_includes pairs, [":path", "/test"]
  end

  def test_decode_handles_indexed_fields
    # Use an indexed static table entry (":method" => "GET" is index 17)
    encoder = Quicsilver::Qpack::Encoder.new
    payload = encoder.encode(":method" => "GET")

    pairs = []
    Quicsilver::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_equal [":method", "GET"], pairs.first
  end

  def test_decode_handles_literal_with_name_reference
    # "user-agent" has static table name entry, custom value is literal
    payload = build_qpack_headers("user-agent" => "TestBot/1.0")

    pairs = []
    Quicsilver::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_includes pairs, ["user-agent", "TestBot/1.0"]
  end

  def test_decode_handles_fully_literal
    payload = build_qpack_headers("x-custom" => "value")

    pairs = []
    Quicsilver::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_includes pairs, ["x-custom", "value"]
  end

  def test_decode_with_empty_payload
    pairs = []
    Quicsilver::Qpack::HeaderBlockDecoder.new.decode("") { |n, v| pairs << [n, v] }

    assert_empty pairs
  end

  def test_decode_with_short_payload
    # Only prefix bytes, no field lines
    pairs = []
    Quicsilver::Qpack::HeaderBlockDecoder.new.decode("\x00\x00".b) { |n, v| pairs << [n, v] }

    assert_empty pairs
  end

  # === RequestParser injectable decoder ===

  def test_request_parser_accepts_decoder_kwarg
    payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost",
      ":path" => "/"
    )
    frame = build_frame(0x01, payload)

    decoder = Quicsilver::Qpack::HeaderBlockDecoder.new
    parser = Quicsilver::HTTP3::RequestParser.new(frame, decoder: decoder)
    parser.parse

    assert_equal "GET", parser.headers[":method"]
    assert_equal "/", parser.headers[":path"]
  end

  def test_request_parser_uses_default_decoder
    # No decoder: kwarg — should still work
    payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "localhost",
      ":path" => "/"
    )
    frame = build_frame(0x01, payload)

    parser = Quicsilver::HTTP3::RequestParser.new(frame)
    parser.parse

    assert_equal "GET", parser.headers[":method"]
  end

  def test_request_parser_uses_custom_decoder
    # A custom decoder that adds a synthetic header
    custom_decoder = Object.new
    def custom_decoder.decode(payload)
      yield ":method", "GET"
      yield ":scheme", "https"
      yield ":path", "/"
      yield "x-injected", "from-custom-decoder"
    end

    # Payload content doesn't matter — custom decoder ignores it
    frame = build_frame(0x01, "\x00\x00".b)
    parser = Quicsilver::HTTP3::RequestParser.new(frame, decoder: custom_decoder)
    parser.parse

    assert_equal "from-custom-decoder", parser.headers["x-injected"]
    assert_equal "GET", parser.headers[":method"]
  end

  # === ResponseParser injectable decoder ===

  def test_response_parser_accepts_decoder_kwarg
    payload = build_qpack_response_headers(200, { "content-type" => "text/plain" })
    frame = build_frame(0x01, payload)

    decoder = Quicsilver::Qpack::HeaderBlockDecoder.new
    parser = Quicsilver::HTTP3::ResponseParser.new(frame, decoder: decoder)
    parser.parse

    assert_equal 200, parser.status
    assert_equal "text/plain", parser.headers["content-type"]
  end

  def test_response_parser_uses_default_decoder
    payload = build_qpack_response_headers(200, {})
    frame = build_frame(0x01, payload)

    parser = Quicsilver::HTTP3::ResponseParser.new(frame)
    parser.parse

    assert_equal 200, parser.status
  end

  def test_response_parser_uses_custom_decoder
    custom_decoder = Object.new
    def custom_decoder.decode(payload)
      yield ":status", "201"
      yield "x-injected", "custom"
    end

    frame = build_frame(0x01, "\x00\x00".b)
    parser = Quicsilver::HTTP3::ResponseParser.new(frame, decoder: custom_decoder)
    parser.parse

    assert_equal 201, parser.status
    assert_equal "custom", parser.headers["x-injected"]
  end

  # === Validation still works with injected decoder ===

  def test_request_parser_validation_with_injected_decoder
    payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":authority" => "example.com",
      ":path" => "/",
      "host" => "other.com"
    )
    frame = build_frame(0x01, payload)

    decoder = Quicsilver::Qpack::HeaderBlockDecoder.new
    parser = Quicsilver::HTTP3::RequestParser.new(frame, decoder: decoder)
    parser.parse

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.validate_headers!
    end
  end

  private

  def build_frame(type, payload)
    Quicsilver::HTTP3.encode_varint(type) +
      Quicsilver::HTTP3.encode_varint(payload.bytesize) +
      payload
  end

  def build_qpack_headers(headers)
    Quicsilver::Qpack::Encoder.new(huffman: false).encode(headers)
  end

  def build_qpack_response_headers(status, headers)
    Quicsilver::Qpack::Encoder.new(huffman: false).encode(
      { ":status" => status.to_s }.merge(headers)
    )
  end
end
