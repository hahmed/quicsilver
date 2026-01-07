# frozen_string_literal: true

require "test_helper"

class ServerClientIntegrationTest < Minitest::Test
  def setup
    @port = 4433 + rand(1000)
    @server = nil
    @server_thread = nil
  end

  def teardown
    @server&.stop
    @server_thread&.kill
  end

  def test_server_receives_and_responds_to_get_request
    app = ->(env) {
      [200, { "content-type" => "text/plain" }, ["Hello from #{env['REQUEST_METHOD']} #{env['PATH_INFO']}"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.connect

    response = client.get("/test-path")

    assert_equal 200, response[:status]
    assert_equal "Hello from GET /test-path", response[:body]
  ensure
    client&.disconnect
  end

  def test_server_receives_post_body
    received_body = nil
    app = ->(env) {
      received_body = env["rack.input"].read
      [200, {}, ["Got #{received_body.bytesize} bytes"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.connect

    response = client.post("/upload", body: "test body content")

    assert_equal 200, response[:status]
    assert_equal "test body content", received_body
  ensure
    client&.disconnect
  end

  def test_multiple_sequential_requests
    request_count = 0
    app = ->(env) {
      request_count += 1
      [200, {}, ["Request ##{request_count}"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.connect

    responses = 3.times.map { client.get("/") }

    assert_equal 3, request_count
    assert(responses.all? { |r| r[:status] == 200 })
  ensure
    client&.disconnect
  end

  def test_request_headers_are_passed_to_app
    received_headers = {}
    app = ->(env) {
      received_headers[:user_agent] = env["HTTP_USER_AGENT"]
      received_headers[:custom] = env["HTTP_X_CUSTOM_HEADER"]
      [200, {}, ["OK"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.connect

    client.get("/", headers: {
      "user-agent" => "Quicsilver/Test",
      "x-custom-header" => "custom-value"
    })

    assert_equal "Quicsilver/Test", received_headers[:user_agent]
    assert_equal "custom-value", received_headers[:custom]
  ensure
    client&.disconnect
  end

  def test_response_headers_are_returned
    app = ->(env) {
      [200, { "x-custom-response" => "response-value", "content-type" => "application/json" }, ["OK"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.connect

    response = client.get("/")

    assert_equal "response-value", response[:headers]["x-custom-response"]
    assert_equal "application/json", response[:headers]["content-type"]
  ensure
    client&.disconnect
  end

  def test_put_request
    app = ->(env) { [200, {}, ["Updated"]] }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.connect

    response = client.put("/resource/123", body: '{"name":"updated"}')

    assert_equal 200, response[:status]
    assert_equal "Updated", response[:body]
  ensure
    client&.disconnect
  end

  private

  def start_server(app)
    config = Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path)
    @server = Quicsilver::Server.new(@port, app: app, server_configuration: config)

    @server_thread = Thread.new { @server.start }
    sleep 0.5 # Wait for server to bind
  end
end
