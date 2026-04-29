# frozen_string_literal: true

require "test_helper"

class ServerClientIntegrationTest < Minitest::Test
  def setup
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

    response = client.put("/resource/123", body: '{"name":"updated"}')

    assert_equal 200, response[:status]
    assert_equal "Updated", response[:body]
  ensure
    client&.disconnect
  end

  def test_server_survives_rack_app_exception
    crashing_app = ->(_env) { raise "intentional test crash" }

    start_server(crashing_app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    response = client.get("/")

    assert_equal 500, response[:status]
    assert @server.running?, "Server should still be running after app exception"
  ensure
    client&.disconnect
  end

  def test_client_connect_disconnect_cycle
    app = ->(_env) { [200, {}, ["OK"]] }

    start_server(app)

    3.times do
      client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
      client.get("/")        # auto-connects
      assert client.connected?
      client.disconnect
      sleep 0.02
    end

    assert @server.running?, "Server should still be running after client disconnect cycles"
  end

  def test_large_post_body
    received_body = nil
    app = ->(env) {
      received_body = env["rack.input"].read
      [200, { "content-type" => "text/plain" }, ["received #{received_body.bytesize} bytes"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # 256KB body — large enough to potentially split across RECEIVE events
    large_body = "x" * 262_144
    response = client.post("/upload", body: large_body)

    assert_equal 200, response[:status]
    assert_equal large_body.bytesize, received_body&.bytesize
    assert_equal large_body, received_body
  ensure
    client&.disconnect
  end

  def test_post_body_integrity_across_requests
    bodies = []
    app = ->(env) {
      bodies << env["rack.input"].read
      [200, {}, ["ok"]]
    }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    payloads = ["small", "a" * 1024, "b" * 65_536]
    payloads.each { |p| client.post("/", body: p) }

    assert_equal 3, bodies.size
    payloads.each_with_index do |expected, i|
      assert_equal expected, bodies[i], "Body mismatch on request #{i}"
    end
  ensure
    client&.disconnect
  end

  # --- Connection pool behavior ---

  def test_class_level_get_reuses_connections
    app = ->(_env) { [200, {}, ["OK"]] }
    start_server(app)

    Quicsilver::Client.close_pool # start fresh

    5.times { Quicsilver::Client.get("127.0.0.1", @port, "/", unsecure: true) }

    # Pool should have created only 1 connection, not 5
    assert_equal 1, Quicsilver::Client.pool.size
  ensure
    Quicsilver::Client.close_pool
  end

  def test_instance_client_auto_connects_on_first_request
    app = ->(_env) { [200, {}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    refute client.connected?

    response = client.get("/")

    assert_equal 200, response[:status]
    assert client.connected?
  ensure
    client&.disconnect
  end

  def test_disconnect_closes_connection
    app = ->(_env) { [200, {}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.get("/")
    assert client.connected?

    client.disconnect
    refute client.connected?
  end

  # === Multi-threaded concurrent clients ===

  def test_multiple_clients_connect_and_request_concurrently
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["ok"]] }
    start_server(app)

    errors = []
    mu = Mutex.new

    # 4 threads, each creating their own client and making requests
    threads = 4.times.map do |i|
      Thread.new do
        client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true, connection_timeout: 5000)
        5.times { client.get("/thread-#{i}") }
        client.disconnect
      rescue => e
        mu.synchronize { errors << "Thread #{i}: #{e.class} #{e.message}" }
      end
    end
    threads.each(&:join)

    assert_empty errors, "Concurrent clients should not error: #{errors.join(', ')}"
  end

  # === Large response (multiple RECEIVE events) ===

  def test_large_response_body_received_correctly
    body = "x" * 50_000  # 50KB — splits across multiple QUIC packets/RECEIVE events
    app = ->(env) { [200, {"content-type" => "application/octet-stream"}, [body]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/large")

    assert_equal 200, response[:status]
    assert_equal 50_000, response[:body].bytesize
    assert_equal body, response[:body]
  ensure
    client&.disconnect
  end

  # === 1xx informational response handling (RFC 9114 §4.1) ===

  def test_client_skips_103_early_hints_and_receives_final_response
    app = ->(env) {
      env["rack.early_hints"]&.call("link" => "</style.css>; rel=preload")
      [200, {"content-type" => "text/html"}, ["Hello"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response[:status]
    assert_equal "Hello", response[:body]
  ensure
    client&.disconnect
  end

  def test_client_receives_200_without_prior_informational
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response[:status]
    assert_equal "OK", response[:body]
  ensure
    client&.disconnect
  end

  # === Trailer reception ===

  def test_client_receives_trailers_in_response
    app = ->(request) {
      headers = Protocol::HTTP::Headers.new
      headers.add("content-type", "text/plain")
      headers.trailer!
      headers.add("grpc-status", "0")
      Protocol::HTTP::Response[200, headers, ["Hello"]]
    }
    start_server(app, mode: :falcon)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response[:status]
    assert_equal "Hello", response[:body]
    assert_equal "0", response[:trailers]["grpc-status"]
  ensure
    client&.disconnect
  end

  def test_client_response_without_trailers_has_empty_trailers
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal({}, response[:trailers])
  ensure
    client&.disconnect
  end

  # === Request body streaming ===

  def test_streaming_request_body_received_by_server
    received_body = nil
    app = ->(env) {
      received_body = env["rack.input"]&.read
      [200, {"content-type" => "text/plain"}, ["got #{received_body.bytesize} bytes"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    req = client.build_request("POST", "/upload", body: :stream)
    req.stream_body do |writer|
      writer.write("chunk1")
      writer.write("chunk2")
      writer.write("chunk3")
    end
    resp = req.response(timeout: 5)

    assert_equal 200, resp[:status]
    assert_equal "chunk1chunk2chunk3", received_body
  ensure
    client&.disconnect
  end

  def test_streaming_empty_body
    app = ->(env) {
      body = env["rack.input"]&.read || ""
      [200, {"content-type" => "text/plain"}, ["got #{body.bytesize} bytes"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    req = client.build_request("POST", "/empty", body: :stream)
    req.stream_body do |writer|
      # No writes
    end
    resp = req.response(timeout: 5)

    assert_equal 200, resp[:status]
    assert_includes resp[:body], "0 bytes"
  ensure
    client&.disconnect
  end

  # === Response body streaming ===

  def test_streaming_response_reads_body_incrementally
    app = ->(env) {
      body = ["chunk1", "chunk2", "chunk3"]
      [200, {"content-type" => "application/octet-stream"}, body]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    req = client.build_request("GET", "/stream")
    streaming = req.streaming_response(timeout: 5)

    assert_equal 200, streaming.status
    body = "".b
    while (chunk = streaming.body.read)
      body << chunk
    end
    assert_equal "chunk1chunk2chunk3", body
  ensure
    client&.disconnect
  end

  def test_streaming_and_buffered_both_work_for_same_request
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["Hello"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # Buffered
    resp = client.get("/")
    assert_equal 200, resp[:status]
    assert_equal "Hello", resp[:body]

    # Streaming
    req = client.build_request("GET", "/")
    streaming = req.streaming_response(timeout: 5)
    assert_equal 200, streaming.status
    body = "".b
    while (chunk = streaming.body.read)
      body << chunk
    end
    assert_equal "Hello", body
  ensure
    client&.disconnect
  end

  # === Stream ID tracking (RFC 9114 §5.2 GOAWAY needs correct stream IDs) ===

  # MsQuic defers stream ID assignment until data flows on the wire.
  # Verify callbacks receive the correct sequential IDs.
  def test_callbacks_receive_sequential_stream_ids
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["ok"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    seen_ids = []
    original = client.method(:handle_stream_event)
    client.define_singleton_method(:handle_stream_event) do |stream_id, event, data, early_data|
      seen_ids << stream_id if event == "RECEIVE_FIN" && (stream_id & 0x02) == 0
      original.call(stream_id, event, data, early_data)
    end

    3.times { |i| client.get("/test-#{i}") }

    assert_equal [0, 4, 8], seen_ids,
      "Client bidi stream IDs should be sequential: 0, 4, 8"
  ensure
    client&.disconnect
  end

  def test_multiple_sequential_requests_all_succeed
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["ok"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    10.times do |i|
      resp = client.get("/count/#{i}")
      assert_equal 200, resp[:status], "Request #{i} should succeed"
    end
  ensure
    client&.disconnect
  end

  private

  def start_server(app, **options)
    3.times do |attempt|
      @port = find_available_port
      config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path, **options)
      @server = Quicsilver::Server.new(@port, app: app, server_configuration: config)

      @server_thread = Thread.new { @server.start }
      begin
        wait_for_server(@server)
        return
      rescue RuntimeError => e
        raise unless e.message.include?("failed to start") && attempt < 2

        @server.shutdown rescue nil
      end
    end
  end
end
