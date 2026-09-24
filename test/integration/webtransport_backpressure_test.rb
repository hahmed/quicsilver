# frozen_string_literal: true

require_relative "../webtransport_helper"

# Backpressure pauses native delivery when the application is not reading.
# These cases run through real CONNECT establishment against a live peer.
#
# The connection receive window is deliberately small so shared-credit
# exhaustion is reached deterministically, rather than by opening streams
# until something times out.
class WebTransportBackpressureTest < Minitest::Test
  include WebTransportHelpers

  # Client#open_stream is private; expose it for raw WebTransport framing.
  class PeerClient < Quicsilver::Client
    attr_reader :events

    def initialize(...)
      @events = Queue.new
      super
    end

    def open_raw_stream(unidirectional: false)
      unidirectional ? open_unidirectional_stream : open_stream
    end

    def handle_stream_event(stream_id, event, data, early_data)
      @events << [stream_id, event, data]
      super
    end
  end

  CONNECTION_WINDOW = 128 * 1024
  STREAM_WINDOW = 32 * 1024
  RECEIVE_BYTES = 4096

  def setup
    @port = find_available_port
    config = Quicsilver::Transport::Configuration.new(
      cert_file_path, key_file_path,
      connection_flow_control_window: CONNECTION_WINDOW,
      stream_receive_window: STREAM_WINDOW,
      max_unidirectional_streams: 100
    )
    @sessions = Queue.new
    @receive_options = {
      receive_backpressure: true, receive_buffer_bytes: RECEIVE_BYTES, receive_buffer_chunks: 64
    }
    app = ->(env) do
      if (session = env["quicsilver.context"]&.webtransport)
        session.accept!(**@receive_options)
        @sessions << session
        [200, {}, []]
      else
        [200, {}, ["OK"]]
      end
    end
    @server = Quicsilver::Server.new(@port, server_configuration: config, app: app)
    Quicsilver::Server.instance = @server
    @server_thread = Thread.new { @server.start }
    wait_for_server(@server)
    @client = PeerClient.new("localhost", @port, unsecure: true, request_timeout: 3)
    assert_equal 200, @client.get("/").status
  end

  def teardown
    @client&.disconnect
    @server&.stop
    @server_thread&.join(3)
  end

  # Many pause/resume cycles: 2 MiB through a 4 KiB budget must arrive intact
  # and in order.
  def test_sustained_transfer_through_a_small_budget
    session = open_session
    peer, stream = open_child(session)
    # Numbered chunks so a reordered or dropped resume is visible, ~2 MiB total.
    payload = (0...65_536).map { |i| format("%08d-quicsilver-backpressure-", i) }.join.b
    assert_operator payload.bytesize, :>, 128 * RECEIVE_BYTES, "payload must force many resumes"

    writer = Thread.new { peer.send(payload, fin: true) }
    received = drain_to_eof(stream)

    assert_equal payload.bytesize, received.bytesize
    assert_equal payload, received, "resumed delivery must preserve order"
    writer.join(5)
  end

  def test_peer_reset_while_input_is_paused
    session = open_session
    peer, stream = open_child(session)
    codes = Queue.new
    stream.on_peer_reset { |code| codes << code }
    peer.send("x".b * (RECEIVE_BYTES * 4))
    await_paused_input(stream)

    peer.reset(Quicsilver::Protocol::WebTransport.application_error_to_http(42))

    assert_equal 42, codes.pop(timeout: 3)
    assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { drain_stream(stream, 1) }
    # The write half survives a peer reset, even with input paused, and the
    # response must actually reach the peer.
    assert stream.open?
    stream.write("still writable")
    stream.close_write
    assert_equal "still writable", await_peer_delivery(stream.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_session_close_while_input_is_paused
    session = open_session
    peer, stream = open_child(session)
    peer.send("x".b * (RECEIVE_BYTES * 4))
    await_paused_input(stream)

    session.close(code: 0, reason: "done")

    assert_raises(Quicsilver::Server::WebTransportStream::ResetError, IOError) { drain_stream(stream, 1) }
    refute session.open?
    assert_equal 200, @client.get("/").status
  end

  # A deferred suffix holds native connection credit. Establish the sibling
  # first, then saturate receiving until its data can no longer be delivered.
  # The stall is asserted; the amount needed to cause it is not, since MsQuic
  # grows stream windows dynamically.
  def test_shared_credit_exhaustion_recovers_after_draining
    session = open_session
    sibling_peer, sibling = open_child(session)
    stalled = Array.new(6) { open_child(session) }

    # One durable reader: a reader that is killed mid-read can drop a chunk it
    # has already dequeued, which would look like a stall that never recovers.
    chunks = Queue.new
    sibling_reader = Thread.new do
      while (chunk = sibling.read)
        chunks << chunk
      end
    end
    sibling_reader.report_on_exception = false

    # Nobody reads the stalled streams, so their deferred suffixes retain
    # connection credit. Saturate well past the connection window first: the
    # sibling must be sent afterwards, or it is delivered before any stall and
    # the assertion below passes for the wrong reason.
    4.times { |i| stalled.each { |peer, _| peer.send("x".b * CONNECTION_WINDOW, fin: i == 3) } }
    sibling_peer.send("sibling payload".b, fin: true)

    assert_nil chunks.pop(timeout: 1),
      "sibling was still delivered; shared credit was never exhausted"

    # Recover by draining the stalled streams rather than cancelling them.
    drainers = stalled.map do |_, stream|
      Thread.new do
        total = 0
        while (chunk = stream.read)
          total += chunk.bytesize
        end
        total
      end
    end
    drainers.each { |drainer| drainer.report_on_exception = false }

    # Delivery may be split across chunks, so accumulate to the full payload.
    assert_equal "sibling payload", collect(chunks, "sibling payload".bytesize),
      "sibling did not recover after the stalled streams were drained"

    drainers.each do |reader|
      assert reader.join(10), "Saturation stream failed to drain"
      assert_equal 4 * CONNECTION_WINDOW, reader.value
    end
    assert sibling_reader.join(3), "Sibling FIN missing"
    assert_equal 200, @client.get("/").status
  ensure
    sibling_reader&.kill
    drainers&.each(&:kill)
  end

  private

  def open_session
    peer = @client.open_raw_stream
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "CONNECT"], [":protocol", "webtransport-h3"],
      [":scheme", "https"], [":authority", "localhost"], [":path", "/wt"]
    ])
    peer.send(headers)
    session = @sessions.pop(timeout: 3)
    refute_nil session, "CONNECT did not reach the application"
    session
  end

  def open_child(session, unidirectional: false)
    accepted = Queue.new
    session.on_stream { |stream| accepted << stream }
    session.on_uni_stream { |stream| accepted << stream }
    peer = @client.open_raw_stream(unidirectional: unidirectional)
    type = unidirectional ? 0x54 : 0x41
    peer.send(Quicsilver::Protocol.encode_varint(type) + Quicsilver::Protocol.encode_varint(session.stream_id))
    stream = accepted.pop(timeout: 3)
    refute_nil stream, "WebTransport child was not accepted"
    [peer, stream]
  end

  # Wait for the Ruby queue to fill, which is the precondition for MsQuic
  # deferring a suffix. Fails rather than proceeding without the precondition.
  # Note this proves the queue is full, not that a suffix is already deferred.
  def await_paused_input(stream, timeout: 3)
    queue = stream.instance_variable_get(:@receive_queue)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(0.01) until queue.available_bytes.zero? ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal 0, queue.available_bytes,
      "receive queue never filled, so input was never paused"
  end

  def await_peer_delivery(stream_id, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    received = "".b
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_operator remaining, :>, 0, "Timed out awaiting peer delivery on #{stream_id}"
      event = @client.events.pop(timeout: remaining)
      refute_nil event, "Timed out awaiting peer delivery on #{stream_id}"
      next unless event[0] == stream_id && %w[RECEIVE RECEIVE_FIN].include?(event[1])

      received << Quicsilver::Transport::StreamEvent.new(event[2], event[1]).data
      return received if event[1] == "RECEIVE_FIN"
    end
  end
end
