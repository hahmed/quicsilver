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
    request = @adapter.build_request(headers)

    assert_equal "GET", request.method
    assert_equal "/hello", request.path
    assert_equal "https", request.scheme
    assert_equal "example.com", request.authority
    assert_equal "HTTP/3", request.version
    assert_nil request.body, "GET should not have a body"
  end

  def test_bodyless_vs_body_methods
    %w[GET HEAD TRACE].each do |method|
      headers = { ":method" => method, ":scheme" => "https", ":path" => "/", ":authority" => "x.com" }
      request = @adapter.build_request(headers)
      assert_nil request.body, "#{method} should not have a body"
    end

    %w[POST PUT PATCH DELETE OPTIONS].each do |method|
      headers = { ":method" => method, ":scheme" => "https", ":path" => "/", ":authority" => "x.com" }
      request = @adapter.build_request(headers)
      assert_instance_of Quicsilver::Protocol::StreamInput, request.body, "#{method} should have a body"
    end
  end

  def test_connect_request
    headers = { ":method" => "CONNECT", ":authority" => "proxy.example.com:443" }
    request = @adapter.build_request(headers)

    assert_equal "CONNECT", request.method
    assert_equal "proxy.example.com:443", request.authority
    assert_instance_of Quicsilver::Protocol::StreamInput, request.body
  end

  def test_post_with_empty_body
    headers = { ":method" => "POST", ":scheme" => "https", ":path" => "/", ":authority" => "x.com" }
    request = @adapter.build_request(headers)
    request.body.close_write

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
    request = adapter.build_request(headers)

    app_thread = Thread.new { adapter.call(request) }

    sleep 0.01
    request.body.write("part1")
    request.body.write("part2")
    request.body.close_write

    response = app_thread.value
    assert_equal 200, response.status
    assert_equal "part1part2", received_body
  end

  def test_send_response_writer_error_propagates
    body = Protocol::HTTP::Body::Buffered.wrap("data")
    response = Protocol::HTTP::Response.new("h3", 200, Protocol::HTTP::Headers.new, body)
    writer = ->(data, fin) { raise "transport error" }

    assert_raises(RuntimeError) { @adapter.send_response(response, writer) }
  end
end
