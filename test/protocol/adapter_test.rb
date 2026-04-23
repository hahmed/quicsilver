# frozen_string_literal: true

require_relative "../test_helper"
require "quicsilver/protocol/adapter"
require "protocol/http/request"
require "protocol/http/response"
require "protocol/http/headers"
require "protocol/http/body/buffered"

class Quicsilver::Protocol::AdapterTest < Minitest::Test
  def setup
    @app = ->(request) {
      body = Protocol::HTTP::Body::Buffered.wrap("Hello")
      Protocol::HTTP::Response.new("h3", 200, {}, body)
    }
    @adapter = Quicsilver::Protocol::Adapter.new(@app)
  end

  def test_build_request
    headers = {
      ":method" => "GET", ":scheme" => "https",
      ":authority" => "example.com", ":path" => "/hello"
    }
    request, body = @adapter.build_request(headers)

    assert_equal "GET", request.method
    assert_equal "/hello", request.path
    assert_equal "https", request.scheme
    assert_equal "example.com", request.authority
    assert_equal "HTTP/3", request.version
    assert_nil body, "GET should not have an input body"
    assert_nil request.body, "GET should not have a body"
  end

  def test_bodyless_vs_body_methods
    %w[GET HEAD TRACE].each do |method|
      headers = { ":method" => method, ":scheme" => "https", ":path" => "/", ":authority" => "x.com" }
      request, body = @adapter.build_request(headers)
      assert_nil body, "#{method} should not have an input body"
    end

    %w[POST PUT PATCH DELETE OPTIONS].each do |method|
      headers = { ":method" => method, ":scheme" => "https", ":path" => "/", ":authority" => "x.com" }
      request, body = @adapter.build_request(headers)
      assert_instance_of Quicsilver::Protocol::StreamInput, body, "#{method} should have an input body"
    end
  end

  def test_connect_request
    headers = { ":method" => "CONNECT", ":authority" => "proxy.example.com:443" }
    request, body = @adapter.build_request(headers)

    assert_equal "CONNECT", request.method
    assert_equal "proxy.example.com:443", request.authority
    assert_instance_of Quicsilver::Protocol::StreamInput, body
  end

  def test_post_with_empty_body
    headers = { ":method" => "POST", ":scheme" => "https", ":path" => "/", ":authority" => "x.com" }
    request, body = @adapter.build_request(headers)
    body.close_write

    response = @adapter.call(request)
    assert_equal 200, response.status
  end

  def test_streaming_input_body
    received_body = nil
    app = ->(request) {
      chunks = []
      while (chunk = request.body&.read)
        chunks << chunk
      end
      received_body = chunks.join
      Protocol::HTTP::Response.new("h3", 200, {}, nil)
    }
    adapter = Quicsilver::Protocol::Adapter.new(app)

    headers = { ":method" => "POST", ":scheme" => "https", ":path" => "/upload", ":authority" => "x.com" }
    request, body = adapter.build_request(headers)

    app_thread = Thread.new { adapter.call(request) }

    sleep 0.01
    body.write("part1")
    body.write("part2")
    body.close_write

    response = app_thread.value
    assert_equal 200, response.status
    assert_equal "part1part2", received_body
  end

  # === Trailer support ===

  def test_send_response_with_trailers
    headers = Protocol::HTTP::Headers.new
    headers.add("content-type", "text/plain")
    headers.trailer!
    headers.add("x-checksum", "abc123")

    body = Protocol::HTTP::Body::Buffered.wrap("Hello")
    response = Protocol::HTTP::Response.new("h3", 200, headers, body)

    sent = "".b
    writer = ->(data, fin) { sent << data }

    @adapter.send_response(response, writer)

    parser = Quicsilver::Protocol::ResponseParser.new(sent)
    parser.parse
    assert_equal 200, parser.status
    assert_equal "Hello", parser.body.read
    assert_equal "abc123", parser.trailers["x-checksum"]
  end

  def test_send_response_streaming_with_trailers
    headers = Protocol::HTTP::Headers.new
    headers.add("content-type", "text/plain")
    headers.trailer!
    headers.add("x-checksum", "abc123")

    body = Protocol::HTTP::Body::Buffered.wrap("streaming body")
    response = Protocol::HTTP::Response.new("h3", 200, headers, body)

    frames = []
    writer = ->(data, fin) { frames << [data, fin] }

    @adapter.send_response(response, writer)

    # Last frame should be the trailer with FIN=true
    assert frames.last[1], "Final frame (trailer) must have FIN=true"

    # Non-final frames should not have FIN
    frames[0..-2].each_with_index do |frame, i|
      refute frame[1], "Frame #{i} should not have FIN"
    end

    # Round-trip: parse all frames together
    all_data = frames.map(&:first).join
    parser = Quicsilver::Protocol::ResponseParser.new(all_data)
    parser.parse
    assert_equal 200, parser.status
    assert_equal "streaming body", parser.body.read
    assert_equal "abc123", parser.trailers["x-checksum"]
  end

  def test_send_response_without_trailers_has_empty_trailers
    body = Protocol::HTTP::Body::Buffered.wrap("Hello")
    response = Protocol::HTTP::Response.new("h3", 200, Protocol::HTTP::Headers.new, body)

    sent = "".b
    writer = ->(data, fin) { sent << data }

    @adapter.send_response(response, writer)

    parser = Quicsilver::Protocol::ResponseParser.new(sent)
    parser.parse
    assert_empty parser.trailers
  end

  # === Extended CONNECT (RFC 9220) ===

  def test_build_request_with_connect_protocol
    headers = {
      ":method" => "CONNECT",
      ":authority" => "example.com",
      ":path" => "/cable",
      ":protocol" => "websocket",
      ":scheme" => "https"
    }
    request, body = @adapter.build_request(headers)

    assert_equal "CONNECT", request.method
    assert_equal "/cable", request.path
    assert_equal "websocket", request.protocol
  end

  def test_send_response_writer_error_propagates
    body = Protocol::HTTP::Body::Buffered.wrap("data")
    response = Protocol::HTTP::Response.new("h3", 200, Protocol::HTTP::Headers.new, body)
    writer = ->(data, fin) { raise "transport error" }

    assert_raises(RuntimeError) { @adapter.send_response(response, writer) }
  end
end
