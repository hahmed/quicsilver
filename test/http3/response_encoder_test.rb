# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/quicsilver/http3"
require_relative "../../lib/quicsilver/http3/response_encoder"
require_relative "../../lib/quicsilver/http3/response_parser"

class ResponseEncoderTest < Minitest::Test
  def test_encode_200_response
    data = encoder(200, { "content-type" => "text/plain" }, ["Hello World"]).encode

    assert_decoded_status(data, 200)
    assert_decoded_header(data, "content-type", "text/plain")
    assert_equal "Hello World", parse_body(data)
  end

  def test_encode_404_response
    data = encoder(404, { "content-type" => "text/plain" }, ["Not Found"]).encode

    assert_decoded_status(data, 404)
    assert_equal "Not Found", parse_body(data)
  end

  def test_encode_500_response
    data = encoder(500, {}, ["Internal Error"]).encode

    assert_decoded_status(data, 500)
    assert_equal "Internal Error", parse_body(data)
  end

  # Status code handling
  def test_encode_common_status_codes
    [200, 204, 304, 400, 403, 404, 500].each do |status|
      data = encoder(status, {}, ["response"]).encode
      assert_decoded_status(data, status)
    end
  end

  def test_encode_non_standard_status_codes
    [201, 202, 301, 302, 401, 418, 502, 503].each do |status|
      data = encoder(status, {}, ["response"]).encode
      assert_decoded_status(data, status)
    end
  end

  # Header handling
  def test_encode_with_multiple_headers
    headers = {
      "content-type" => "application/json",
      "cache-control" => "no-cache",
      "x-custom-header" => "custom-value"
    }
    data = encoder(200, headers, ["body"]).encode

    assert_decoded_header(data, "content-type", "application/json")
    assert_decoded_header(data, "cache-control", "no-cache")
    assert_decoded_header(data, "x-custom-header", "custom-value")
  end

  def test_encode_headers_are_downcased
    headers = {
      "Content-Type" => "text/html",
      "X-Custom-Header" => "value"
    }
    data = encoder(200, headers, ["test"]).encode

    assert_decoded_header(data, "content-type", "text/html")
    assert_decoded_header(data, "x-custom-header", "value")
  end

  def test_encode_skips_rack_internal_headers
    headers = {
      "content-type" => "text/plain",
      "rack.version" => [1, 3],
      "rack.url_scheme" => "https",
      "x-custom" => "value"
    }
    data = encoder(200, headers, ["test"]).encode

    assert_decoded_header(data, "content-type", "text/plain")
    assert_decoded_header(data, "x-custom", "value")
    # Verify rack headers are NOT present
    parser = parse_response(data)
    refute parser.headers.key?("rack.version")
    refute parser.headers.key?("rack.url_scheme")
  end

  def test_encode_with_symbol_header_keys
    headers = {
      content_type: "application/json",
      cache_control: "max-age=3600"
    }
    data = encoder(200, headers, ["test"]).encode

    assert_decoded_header(data, "content_type", "application/json")
    assert_decoded_header(data, "cache_control", "max-age=3600")
  end

  # Body handling
  def test_encode_with_empty_body
    data = encoder(204, {}, []).encode

    assert_decoded_status(data, 204)
    assert_empty parse_body(data)
  end

  def test_encode_with_multiple_body_chunks
    data = encoder(200, {}, ["chunk1", "chunk2", "chunk3"]).encode

    assert_equal "chunk1chunk2chunk3", parse_body(data)
  end

  def test_encode_skips_empty_chunks
    data = encoder(200, {}, ["chunk1", "", "chunk2", "", "chunk3"]).encode

    body = parse_body(data)
    assert_equal "chunk1chunk2chunk3", body
    refute_includes body, "\x00\x00" # No empty DATA frames
  end

  def test_encode_with_large_body
    large_chunk = "x" * 10_000
    data = encoder(200, {}, [large_chunk]).encode

    assert_equal large_chunk, parse_body(data)
  end

  def test_strips_connection_specific_headers
    headers = {
      "content-type" => "text/plain",
      "transfer-encoding" => "chunked",
      "connection" => "keep-alive",
      "keep-alive" => "timeout=5",
      "upgrade" => "websocket",
      "te" => "trailers",
      "x-custom" => "stays"
    }
    data = encoder(200, headers, ["body"]).encode
    parser = parse_response(data)

    refute parser.headers.key?("transfer-encoding")
    refute parser.headers.key?("connection")
    refute parser.headers.key?("keep-alive")
    refute parser.headers.key?("upgrade")
    refute parser.headers.key?("te")
    assert_equal "stays", parser.headers["x-custom"]
  end

  # Body resource management
  def test_encode_closes_body_if_closeable
    body_mock = ["content"]

    def body_mock.close
      @closed = true
    end

    def body_mock.closed?
      @closed ||= false
    end

    encoder(200, {}, body_mock).encode

    assert body_mock.closed?, "Body should be closed after encoding"
  end

  def test_encode_handles_body_without_close_method
    body = ["content"]
    data = encoder(200, {}, body).encode

    assert_decoded_status(data, 200)
    assert_equal "content", parse_body(data)
  end

  # Content type handling
  def test_encode_json_response
    json = '{"status":"ok","message":"Success"}'
    data = encoder(200, { "content-type" => "application/json" }, [json]).encode

    assert_decoded_header(data, "content-type", "application/json")
    assert_equal json, parse_body(data)
  end

  def test_encode_redirect_response
    data = encoder(302, { "location" => "https://example.com/new" }, ["Redirecting"]).encode

    assert_decoded_status(data, 302)
    assert_decoded_header(data, "location", "https://example.com/new")
  end

  def test_encode_binary_content
    binary_data = "\x00\x01\x02\x03\xFF\xFE".b
    data = encoder(200, { "content-type" => "application/octet-stream" }, [binary_data]).encode

    assert_equal binary_data, parse_body(data)
  end

  def test_encode_with_utf8_content
    utf8_content = "Hello 世界 🌍"
    data = encoder(200, { "content-type" => "text/plain; charset=utf-8" }, [utf8_content]).encode

    assert_equal utf8_content.b, parse_body(data)
  end

  # Frame structure
  def test_encode_produces_binary_string
    data = encoder(200, {}, ["test"]).encode

    assert_equal Encoding::BINARY, data.encoding
  end

  def test_encode_produces_valid_frames
    data = encoder(200, { "content-type" => "text/plain" }, ["test"]).encode

    parser = parse_response(data)
    assert_equal 2, parser.frames.length # HEADERS + DATA
    assert_equal Quicsilver::HTTP3::FRAME_HEADERS, parser.frames[0][:type]
    assert_equal Quicsilver::HTTP3::FRAME_DATA, parser.frames[1][:type]
  end

  # Roundtrip tests
  def test_roundtrip_simple_response
    data = encoder(200, { "content-type" => "text/plain" }, ["Hello"]).encode

    assert_decoded_status(data, 200)
    assert_decoded_header(data, "content-type", "text/plain")
    assert_equal "Hello", parse_body(data)
  end

  def test_roundtrip_complex_response
    headers = {
      "content-type" => "application/json",
      "cache-control" => "max-age=3600",
      "x-custom" => "value"
    }
    body = ['{"data":"test"}']

    data = encoder(201, headers, body).encode

    assert_decoded_status(data, 201)
    assert_decoded_header(data, "content-type", "application/json")
    assert_decoded_header(data, "cache-control", "max-age=3600")
    assert_decoded_header(data, "x-custom", "value")
    assert_equal '{"data":"test"}', parse_body(data)
  end

  # Streaming tests
  def test_stream_encode_yields_frames_with_fin_flags
    enc = encoder(200, { "content-type" => "text/plain" }, ["Hello"])
    frames = []
    enc.stream_encode { |data, fin| frames << [data, fin] }

    assert_equal 2, frames.size
    assert_equal false, frames[0][1], "HEADERS should have FIN=false"
    assert_equal true, frames[1][1], "Last DATA should have FIN=true"
  end

  def test_stream_encode_produces_same_result_as_buffered
    body = ["chunk1", "chunk2", "chunk3"]
    headers = { "content-type" => "text/plain" }

    buffered = encoder(200, headers, body.dup).encode

    streamed = "".b
    encoder(200, headers, body.dup).stream_encode { |data, _fin| streamed << data }

    assert_equal buffered, streamed, "Streaming should produce identical output"
  end

  def test_stream_encode_handles_empty_body
    enc = encoder(204, {}, [])
    frames = []
    enc.stream_encode { |data, fin| frames << [data, fin] }

    assert frames.last[1], "Should end with FIN=true"
  end

  private

  def request(method, path, headers = {}, body = [])
    ecoder(status, headers, body).encode
  end

  def encoder(status, headers, body)
    Quicsilver::HTTP3::ResponseEncoder.new(status, headers, body)
  end

  def parse_response(data)
    parser = Quicsilver::HTTP3::ResponseParser.new(data)
    parser.parse
    parser
  end

  def assert_decoded_status(data, expected_status)
    parser = parse_response(data)
    assert_equal expected_status, parser.status, "Expected status #{expected_status}"
  end

  def assert_decoded_header(data, name, value)
    parser = parse_response(data)
    assert_equal value, parser.headers[name], "Expected header #{name} to be #{value}"
  end

  def parse_body(data)
    parser = parse_response(data)
    parser.body.read.b
  end
end
