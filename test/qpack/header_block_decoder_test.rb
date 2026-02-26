# frozen_string_literal: true

require_relative "../http3_test_helper"

class HeaderBlockDecoderTest < Minitest::Test
  include HTTP3TestHelpers

  # === Decoder class exists and works standalone ===

  def test_decode_yields_name_value_pairs
    payload = build_qpack_headers(
      ":method" => "GET",
      ":scheme" => "https",
      ":path" => "/test"
    )

    pairs = []
    Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_includes pairs, [":method", "GET"]
    assert_includes pairs, [":scheme", "https"]
    assert_includes pairs, [":path", "/test"]
  end

  def test_decode_handles_indexed_fields
    encoder = Quicsilver::Protocol::Qpack::Encoder.new
    payload = encoder.encode(":method" => "GET")

    pairs = []
    Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_equal [":method", "GET"], pairs.first
  end

  def test_decode_handles_literal_with_name_reference
    payload = build_qpack_headers("user-agent" => "TestBot/1.0")

    pairs = []
    Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_includes pairs, ["user-agent", "TestBot/1.0"]
  end

  def test_decode_handles_fully_literal
    payload = build_qpack_headers("x-custom" => "value")

    pairs = []
    Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new.decode(payload) { |n, v| pairs << [n, v] }

    assert_includes pairs, ["x-custom", "value"]
  end

  def test_decode_with_empty_payload
    pairs = []
    Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new.decode("") { |n, v| pairs << [n, v] }

    assert_empty pairs
  end

  def test_decode_with_short_payload
    pairs = []
    Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new.decode("\x00\x00".b) { |n, v| pairs << [n, v] }

    assert_empty pairs
  end

  # === RequestParser injectable decoder ===

  def test_request_parser_accepts_decoder_kwarg
    payload = build_qpack_headers(
      ":method" => "GET", ":scheme" => "https",
      ":authority" => "localhost", ":path" => "/"
    )
    decoder = Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new
    parser = Quicsilver::Protocol::RequestParser.new(build_headers_frame( payload), decoder: decoder)
    parser.parse

    assert_equal "GET", parser.headers[":method"]
  end

  def test_request_parser_uses_default_decoder
    payload = build_qpack_headers(
      ":method" => "GET", ":scheme" => "https",
      ":authority" => "localhost", ":path" => "/"
    )
    parser = Quicsilver::Protocol::RequestParser.new(build_headers_frame( payload))
    parser.parse

    assert_equal "GET", parser.headers[":method"]
  end

  def test_request_parser_uses_custom_decoder
    custom_decoder = Object.new
    def custom_decoder.decode(_payload)
      yield ":method", "GET"
      yield ":scheme", "https"
      yield ":path", "/"
      yield "x-injected", "from-custom-decoder"
    end

    parser = Quicsilver::Protocol::RequestParser.new(build_headers_frame( "\x00\x00".b), decoder: custom_decoder)
    parser.parse

    assert_equal "from-custom-decoder", parser.headers["x-injected"]
    assert_equal "GET", parser.headers[":method"]
  end

  # === ResponseParser injectable decoder ===

  def test_response_parser_accepts_decoder_kwarg
    payload = build_qpack_response_headers(200, "content-type" => "text/plain")
    decoder = Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new
    parser = Quicsilver::Protocol::ResponseParser.new(build_headers_frame( payload), decoder: decoder)
    parser.parse

    assert_equal 200, parser.status
    assert_equal "text/plain", parser.headers["content-type"]
  end

  def test_response_parser_uses_default_decoder
    payload = build_qpack_response_headers(200)
    parser = Quicsilver::Protocol::ResponseParser.new(build_headers_frame( payload))
    parser.parse

    assert_equal 200, parser.status
  end

  def test_response_parser_uses_custom_decoder
    custom_decoder = Object.new
    def custom_decoder.decode(_payload)
      yield ":status", "201"
      yield "x-injected", "custom"
    end

    parser = Quicsilver::Protocol::ResponseParser.new(build_headers_frame( "\x00\x00".b), decoder: custom_decoder)
    parser.parse

    assert_equal 201, parser.status
    assert_equal "custom", parser.headers["x-injected"]
  end

  # === Validation still works with injected decoder ===

  def test_request_parser_validation_with_injected_decoder
    payload = build_qpack_headers(
      ":method" => "GET", ":scheme" => "https",
      ":authority" => "example.com", ":path" => "/",
      "host" => "other.com"
    )
    decoder = Quicsilver::Protocol::Qpack::HeaderBlockDecoder.new
    parser = Quicsilver::Protocol::RequestParser.new(build_headers_frame( payload), decoder: decoder)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end
end
