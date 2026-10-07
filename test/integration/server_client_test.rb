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

    assert_equal 200, response.status
    assert_equal "Hello from GET /test-path", response.body
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

    assert_equal 200, response.status
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
    assert(responses.all? { |r| r.status == 200 })
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

    assert_equal "response-value", response.headers["x-custom-response"]
    assert_equal "application/json", response.headers["content-type"]
  ensure
    client&.disconnect
  end

  def test_put_request
    app = ->(env) { [200, {}, ["Updated"]] }

    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    response = client.put("/resource/123", body: '{"name":"updated"}')

    assert_equal 200, response.status
    assert_equal "Updated", response.body
  ensure
    client&.disconnect
  end

  def test_server_survives_rack_app_exception
    crashing_app = ->(_env) { raise "intentional test crash" }

    start_server(crashing_app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    response = client.get("/")

    assert_equal 500, response.status
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

    assert_equal 200, response.status
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

    assert_equal 200, response.status
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

    assert_equal 200, response.status
    assert_equal 50_000, response.body.bytesize
    assert_equal body, response.body
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

    assert_equal 200, response.status
    assert_equal "Hello", response.body
  ensure
    client&.disconnect
  end

  def test_client_receives_200_without_prior_informational
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response.status
    assert_equal "OK", response.body
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

    assert_equal 200, response.status
    assert_equal "Hello", response.body
    assert_equal "0", response.trailers["grpc-status"]
  ensure
    client&.disconnect
  end

  def test_rack_app_sends_trailers_via_rack_trailers
    app = ->(env) {
      env["rack.trailers"] = { "grpc-status" => "0", "grpc-message" => "OK" }
      [200, {"content-type" => "text/plain"}, ["Hello"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response.status
    assert_equal "Hello", response.body
    assert_equal "0", response.trailers["grpc-status"]
    assert_equal "OK", response.trailers["grpc-message"]
  ensure
    client&.disconnect
  end

  def test_rack_app_sends_trailers_on_error_response
    app = ->(env) {
      env["rack.trailers"] = { "grpc-status" => "13", "grpc-message" => "INTERNAL" }
      [500, {"content-type" => "application/grpc"}, [""]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 500, response.status
    assert_equal "13", response.trailers["grpc-status"]
    assert_equal "INTERNAL", response.trailers["grpc-message"]
  ensure
    client&.disconnect
  end

  def test_rack_app_empty_trailers_not_sent
    app = ->(env) {
      env["rack.trailers"] = {}
      [200, {"content-type" => "text/plain"}, ["OK"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response.status
    assert_equal({}, response.trailers)
  ensure
    client&.disconnect
  end

  def test_rack_app_non_hash_trailers_ignored
    app = ->(env) {
      env["rack.trailers"] = "not a hash"
      [200, {"content-type" => "text/plain"}, ["OK"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response.status
    assert_equal({}, response.trailers)
  ensure
    client&.disconnect
  end

  def test_rack_app_trailers_with_multiple_fields
    app = ->(env) {
      env["rack.trailers"] = {
        "grpc-status" => "0",
        "grpc-message" => "OK",
        "x-request-id" => "abc-123",
        "x-timing" => "42ms"
      }
      [200, {"content-type" => "text/plain"}, ["Hello"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response.status
    assert_equal "0", response.trailers["grpc-status"]
    assert_equal "OK", response.trailers["grpc-message"]
    assert_equal "abc-123", response.trailers["x-request-id"]
    assert_equal "42ms", response.trailers["x-timing"]
  ensure
    client&.disconnect
  end

  def test_client_response_without_trailers_has_empty_trailers
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal({}, response.trailers)
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

    assert_equal 200, resp.status
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

    assert_equal 200, resp.status
    assert_includes resp.body, "0 bytes"
  ensure
    client&.disconnect
  end

  def test_streaming_request_with_rack_trailers
    received_body = nil
    app = ->(env) {
      received_body = env["rack.input"]&.read
      env["rack.trailers"] = { "grpc-status" => "0", "grpc-message" => "OK" }
      [200, {"content-type" => "application/grpc"}, ["done"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    req = client.build_request("POST", "/grpc", body: :stream)
    req.stream_body do |writer|
      writer.write("request-data")
    end
    resp = req.response(timeout: 5)

    assert_equal 200, resp.status
    assert_equal "done", resp.body
    assert_equal "request-data", received_body
    assert_equal "0", resp.trailers["grpc-status"]
    assert_equal "OK", resp.trailers["grpc-message"]
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

  def test_streaming_response_delivers_chunks_incrementally
    app = ->(env) {
      body = Enumerator.new do |y|
        3.times do |i|
          y << "chunk#{i}"
          sleep 0.05
        end
      end
      [200, {"content-type" => "text/plain"}, body]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    req = client.build_request("GET", "/stream")
    streaming = req.streaming_response(timeout: 5)

    assert_equal 200, streaming.status

    # Read first chunk — should arrive before all chunks are sent
    first_chunk = streaming.body.read
    assert first_chunk, "Expected at least one chunk"
    assert first_chunk.bytesize > 0

    # Read remaining chunks
    chunks = [first_chunk]
    while (chunk = streaming.body.read)
      chunks << chunk
    end

    assert_equal "chunk0chunk1chunk2", chunks.join
  ensure
    client&.disconnect
  end

  def test_streaming_response_receives_trailers
    app = ->(env) {
      env["rack.trailers"] = { "grpc-status" => "0", "grpc-message" => "OK" }
      [200, {"content-type" => "application/grpc"}, ["response-data"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    req = client.build_request("GET", "/grpc")
    streaming = req.streaming_response(timeout: 5)

    assert_equal 200, streaming.status
    body = "".b
    while (chunk = streaming.body.read)
      body << chunk
    end
    assert_equal "response-data", body

    # Trailers should be available after body is fully read
    resp = req.response(timeout: 5)
    assert_equal "0", resp.trailers["grpc-status"]
    assert_equal "OK", resp.trailers["grpc-message"]
  ensure
    client&.disconnect
  end

  def test_streaming_and_buffered_both_work_for_same_request
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["Hello"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # Buffered
    resp = client.get("/")
    assert_equal 200, resp.status
    assert_equal "Hello", resp.body

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

  # === H3 Datagrams (RFC 9297 / QUIC RFC 9221) ===

  def test_server_sends_datagram_to_client
    received = nil
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.on_datagram { |data| received = data }

    # Make a request to establish the connection
    response = client.get("/")
    assert_equal 200, response.status

    # Server sends a datagram
    connection = @server.connections.values.first
    @server.datagram_send(connection, "hello-datagram")
    sleep 0.1  # allow event loop to deliver

    assert_equal "hello-datagram", received
  ensure
    client&.disconnect
  end

  # Datagrams have no flow control (RFC 9221 §5.3), so a peer can send them
  # faster than the dispatcher delivers them. Each connection may have 128
  # queued; past that the oldest is dropped, and the drop is counted. The
  # on_datagram callback runs on the dispatcher, so stalling it in the
  # callback is how a flood gets ahead of delivery here.
  def test_datagram_flood_drops_oldest_and_counts
    delivered = Queue.new
    stalled = false
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)
    @server.on_datagram do |_conn, data|
      unless stalled
        stalled = true
        sleep 0.5
      end
      delivered << data
    end

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    assert_equal 200, client.get("/").status

    total = 400
    total.times { |i| client.datagram_send(format("d%04d", i)) }
    sleep 1.5

    received = []
    received << delivered.pop until delivered.empty?
    dropped = @server.stats.dig("datagrams", "dropped")

    assert_operator dropped, :>, 0, "a 400-datagram flood against a stalled dispatcher should drop some"
    assert_operator received.size, :<, total
    assert_equal total, received.size + dropped, "every datagram is either delivered or counted as dropped"
    # Oldest dropped, newest kept: the last one sent must have been delivered,
    # and everything delivered after the stall is in send order.
    assert_includes received, format("d%04d", total - 1)
    assert_equal received.drop(1), received.drop(1).sort
  ensure
    client&.disconnect
  end

  def test_client_sends_datagram_to_server
    received = nil
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)
    @server.on_datagram { |_conn, data| received = data }

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # Make a request to establish the connection
    response = client.get("/")
    assert_equal 200, response.status

    # Client sends a datagram
    client.datagram_send("client-datagram")
    sleep 0.1  # allow event loop to deliver

    assert_equal "client-datagram", received
  ensure
    client&.disconnect
  end

  # === Per-request timeout ===

  def test_per_request_timeout_raises_on_slow_response
    app = ->(env) {
      sleep 2
      [200, {"content-type" => "text/plain"}, ["OK"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    assert_raises(Quicsilver::TimeoutError) do
      client.get("/slow", timeout: 0.3)
    end
  ensure
    client&.disconnect
  end

  def test_per_request_timeout_does_not_affect_fast_response
    app = ->(env) { [200, {"content-type" => "text/plain"}, ["fast"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/", timeout: 5)

    assert_equal 200, response.status
    assert_equal "fast", response.body
  ensure
    client&.disconnect
  end

  # === Extensible Priorities (RFC 9218) ===

  def test_client_sends_priority_header
    received_priority = nil
    app = ->(env) {
      received_priority = env["HTTP_PRIORITY"]
      [200, {"content-type" => "text/plain"}, ["OK"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    priority = Quicsilver::Protocol::Priority.new(urgency: 0, incremental: true)
    response = client.get("/", priority: priority)

    assert_equal 200, response.status
    assert_equal "u=0, i", received_priority
  ensure
    client&.disconnect
  end

  def test_client_default_priority_omits_header
    received_priority = nil
    app = ->(env) {
      received_priority = env["HTTP_PRIORITY"]
      [200, {"content-type" => "text/plain"}, ["OK"]]
    }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    response = client.get("/")

    assert_equal 200, response.status
    assert_nil received_priority
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
      seen_ids << stream_id if event == "RECEIVE_FIN" && Quicsilver::Transport::StreamId.request?(stream_id)
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
      assert_equal 200, resp.status, "Request #{i} should succeed"
    end
  ensure
    client&.disconnect
  end

  # Verify client connections don't race with server-side GetParam.
  # The CONNECTED callback only fetches the peer address for server
  # connections — client connections skip it to avoid delaying
  # StreamOpen on slower machines (Linux CI).
  def test_client_connects_without_stream_open_race
    app = ->(_env) { [200, {}, ["ok"]] }
    start_server(app)

    client = Quicsilver::Client.new("localhost", @port, unsecure: true)
    response = client.get("/")
    assert_equal 200, response.status
    client.disconnect
  end

  # === Load shedding ===
  #
  # When the server is at capacity it must answer, and must not keep counting
  # the shed request as in-flight afterwards.
  #
  # The two status assertions below pass with or without the streaming-path
  # fix, because a shed streaming request falls through to the buffered path on
  # RECEIVE_FIN and gets a 503 that way. They are behavioural coverage, not
  # regression proof. The active-request assertion is the discriminating one.

  def test_client_receives_response_when_server_is_at_capacity
    app = ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    response = @server.scheduler.stub(:full?, true) do
      client.get("/render", timeout: 5)
    end

    assert_equal 503, response.status
  ensure
    client&.disconnect
  end

  # A small streamed body still arrives in one RECEIVE_FIN and takes the
  # buffered path. Only a body large enough to be split across RECEIVE events
  # reaches dispatch_streaming, which is the path that used to drop silently.
  def test_streaming_client_receives_response_when_server_is_at_capacity
    app = ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    response = @server.scheduler.stub(:full?, true) do
      request = client.build_request("POST", "/upload", body: :stream)
      request.stream_body { |writer| 20.times { writer.write("x" * 4096) } }
      request.response(timeout: 2)
    end

    assert_equal 503, response.status
  ensure
    client&.disconnect
  end

  # A shed request must not be counted as in-flight afterwards, otherwise an
  # idle server keeps reporting pressure it does not have.
  def test_shedding_does_not_leave_active_requests_behind
    app = ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)

    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    @server.scheduler.stub(:full?, true) do
      2.times do |i|
        request = client.build_request("POST", "/upload-#{i}", body: :stream)
        request.stream_body { |writer| 20.times { writer.write("x" * 4096) } }
        request.response(timeout: 2)
      end
    end

    assert_equal 0, @server.request_registry.active_count
    assert_equal 0, @server.stats["requests"]["active"]
  ensure
    client&.disconnect
  end

  # A shed request has already been answered, so its remaining body must be
  # discarded. Buffering it loses the HEADERS that were consumed with the
  # first chunk, and parsing the rest at FIN reports "DATA frame before
  # HEADERS", which is a connection error and killed every other stream.
  #
  # Sequenced rather than raced: the 503 is read before the rest of the body
  # is sent, so the ordering that used to break the connection is guaranteed.
  def test_shed_request_body_after_the_response_does_not_break_the_connection
    app = ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }
    start_server(app)
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    @server.scheduler.stub(:full?, true) do
      request = client.build_request("POST", "/upload", body: :stream)
      response = nil
      request.stream_body do |writer|
        writer.write("x" * 4096)
        # Read the 503 first, so the body below is guaranteed to arrive after
        # the request was answered and its HEADERS consumed.
        response = request.response(timeout: 5)
        16.times { writer.write("x" * 4096) }
      end

      assert_equal 503, response.status
    end

    # The connection must still serve requests once the queue drains.
    assert_equal 200, client.get("/after").status
  ensure
    client&.disconnect
  end

  # --- Concurrency stress -------------------------------------------------
  #
  # Both of these failed on code the rest of the suite passed. Each pins a
  # property the single-request tests above cannot see.

  # send_stream hands MsQuic a pointer into a Ruby String's bytes rather than
  # a copy, and MsQuic holds that pointer until SEND_COMPLETE. If the String
  # were collected in between, the bytes on the wire would be whatever the
  # allocator reused that memory for; the peer sees a mangled frame, not a
  # crash, so it only shows under GC pressure. The first zero-copy version
  # passed the suite and failed this in under 50 requests.
  def test_sent_bytes_survive_gc_until_send_complete
    app = ->(env) {
      size = Integer(env["QUERY_STRING"].to_s[/\d+/] || 2)
      [200, { "content-type" => "text/plain" }, ["x" * size]]
    }
    start_server(app)
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true, request_timeout: 5)
    client.open_connection

    gc_thread = Thread.new { loop { GC.start; sleep 0.0005 } }
    bad = []
    600.times do |i|
      size = (i % 97) + 1
      response = client.get("/?#{size}")
      next if response&.status == 200 && response.body == "x" * size

      bad << [i, response&.status, response&.body&.bytesize]
    end

    assert_empty bad, "#{bad.size}/600 responses were wrong under GC pressure; first: #{bad.first.inspect}"
  ensure
    gc_thread&.kill
    client&.disconnect
  end

  # Many Ruby threads on one client, server in the same process: the pattern
  # benchmarks/compare.rb uses. Peer streams are registered on the poll thread
  # and client streams on Ruby threads; once the poll thread stopped holding
  # the GVL, a stream token minted outside StateLock was handed to two streams
  # and send_stream resolved to the wrong one. A client received its own GET
  # frame as a response. Fails within a few hundred requests with that race.
  def test_many_threads_on_one_client_get_their_own_responses
    start_server(->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] })
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true, request_timeout: 5)
    client.open_connection

    failures = Queue.new
    Array.new(10) do |t|
      Thread.new do
        150.times do |i|
          response = client.get("/?t=#{t}&i=#{i}")
          failures << [t, i, response&.status, response&.body] unless response&.status == 200 && response.body == "OK"
        rescue StandardError => e
          failures << [t, i, e.class, e.message]
        end
      end
    end.each(&:join)

    bad = []
    bad << failures.pop until failures.empty?
    assert_empty bad, "#{bad.size}/1500 requests failed; first: #{bad.first.inspect}"
  ensure
    client&.disconnect
  end

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
