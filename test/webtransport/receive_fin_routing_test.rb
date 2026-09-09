# frozen_string_literal: true

require_relative "../test_helper"

# WebTransport streams that arrive complete, with FIN, in a single event.
#
# All WebTransport stream classification lives in handle_bidi_receive, which
# only runs on RECEIVE. handle_receive_fin checks whether a stream belongs to a
# known session, but a brand new stream does not yet, so it falls through to
# complete_buffered_request and is parsed as an HTTP/3 request.
#
# A long-lived stream is unaffected: it stays open, so its data arrives on
# RECEIVE and is classified. A short command stream sent with FIN is not.
class WebTransportReceiveFinRoutingTest < Minitest::Test
  Session = Quicsilver::Server::WebTransportSession

  SESSION_ID = 0
  COMMAND_STREAM = 4

  def test_a_complete_bidi_stream_is_routed_to_its_session
    server, connection = server_with_session
    delivered = []
    session.on_stream { |stream| delivered << stream.stream_id }

    receive_fin(server, connection, COMMAND_STREAM, bidi_payload(%({"type":"reaction"})))

    assert_equal [COMMAND_STREAM], delivered,
      "a WebTransport stream arriving with FIN must reach its session"
  end

  # Reaching dispatch_request means the HTTP/3 parser will read the 0x41 prefix
  # as a frame header and raise a connection error, killing every request on
  # the connection. Asserted here rather than on the parser output because the
  # scheduler is not running in these tests, so the parse would never execute.
  def test_a_complete_bidi_stream_never_reaches_the_http3_dispatcher
    server, connection = server_with_session
    dispatched = []

    server.stub(:dispatch_request, ->(_conn, stream, **) { dispatched << stream.stream_id }) do
      receive_fin(server, connection, COMMAND_STREAM, bidi_payload(%({"type":"reaction"})))
    end

    assert_empty dispatched
  end

  # The case that works today, kept so a fix cannot regress it.
  def test_an_ordinary_request_arriving_with_fin_still_reaches_http3
    server, connection = server_with_session
    dispatched = []
    server.stub(:dispatch_request, ->(_conn, stream, **) { dispatched << stream.stream_id }) do
      receive_fin(server, connection, 8, http3_request)
    end

    assert_equal [8], dispatched
  end

  # === STOP_SENDING on a WebTransport stream (draft-16 §4.4) ===
  #
  #   A WebTransport endpoint can send a RESET_STREAM or a STOP_SENDING frame
  #   for a WebTransport data stream. Those signals are propagated by the
  #   WebTransport implementation to the application.
  #
  # The handler did not check for WebTransport streams at all, so it replied
  # with a raw HTTP/3 code and ran cancel_stream, which touches the request
  # registry and pending-stream bookkeeping for a stream that is not a request.

  def test_stop_sending_reaches_the_owning_session
    server, connection = server_with_session
    stream = accept_stream(server, connection, COMMAND_STREAM)
    reported = :unset
    stream.on_reset { |code| reported = code }

    stop_sending(server, connection, COMMAND_STREAM,
      Quicsilver::Protocol::WebTransport.application_error_to_http(42))

    assert_equal 42, reported
  end

  def test_stop_sending_removes_the_stream_from_its_session
    server, connection = server_with_session
    accept_stream(server, connection, COMMAND_STREAM)

    stop_sending(server, connection, COMMAND_STREAM, Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    assert_nil session.stream(COMMAND_STREAM)
  end

  def test_stop_sending_does_not_touch_http3_bookkeeping
    server, connection = server_with_session
    accept_stream(server, connection, COMMAND_STREAM)

    stop_sending(server, connection, COMMAND_STREAM, Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    refute server.cancelled_stream?(COMMAND_STREAM),
      "a WebTransport stream is not a cancelled HTTP/3 request"
  end

  # Ordinary requests must still be cancelled the old way. The HTTP/3 path
  # answers with a real RESET_STREAM, so that call is stubbed out; the
  # assertion is on the cancellation, not the stub.
  def test_stop_sending_on_a_request_stream_still_cancels_it
    server, connection = server_with_session

    Quicsilver.stub(:stream_reset, nil) do
      stop_sending(server, connection, 20, Quicsilver::Protocol::H3_REQUEST_CANCELLED)
    end

    assert server.cancelled_stream?(20)
  end

  def test_unknown_session_is_rejected_without_http_dispatch
    server, connection = server_with_session
    rejected = []
    dispatched = []
    Quicsilver.stub(:stream_abort, ->(*args) { rejected << args }) do
      server.stub(:dispatch_request, ->(*) { dispatched << true }) do
        receive_fin(server, connection, 8, bidi_payload("hello", session_id: 64))
        receive_fin(server, connection, 8, http3_request)
      end
    end

    assert_empty dispatched
    assert_equal [[99_008, Quicsilver::Protocol::WebTransport::BUFFERED_STREAM_REJECTED]], rejected
  end

  def test_split_bidi_prefix_fin_is_delivered_exactly_once
    (1...bidi_payload("").bytesize).each do |split|
      server, connection = server_with_session
      received = []
      session.on_stream { |stream| received << stream }
      payload = bidi_payload("hello")
      receive(server, connection, 4, payload.byteslice(0, split))
      receive_fin(server, connection, 4, payload.byteslice(split..))

      assert_equal "hello", received.fetch(0).read
      assert_nil received.fetch(0).read
    end
  end

  def test_existing_stream_data_is_not_reclassified_as_a_prefix
    server, connection = server_with_session
    received = []
    session.on_stream { |stream| received << stream }
    receive(server, connection, 4, bidi_payload("first"))
    payload = bidi_payload("application bytes", session_id: 64)
    receive(server, connection, 4, payload)

    assert_equal ["first", payload], [received.fetch(0).read, received.fetch(0).read]
  end

  def test_unknown_session_with_split_prefix_is_rejected_on_fin
    server, connection = server_with_session
    payload = bidi_payload("hello", session_id: 64)
    receive(server, connection, 4, payload.byteslice(0, 3))
    rejected = []
    Quicsilver.stub(:stream_abort, ->(*args) { rejected << args }) do
      receive_fin(server, connection, 4, payload.byteslice(3..))
    end

    assert_equal [[99_004, Quicsilver::Protocol::WebTransport::BUFFERED_STREAM_REJECTED]], rejected
  end

  def test_uni_session_prefix_can_finish_with_fin
    server, connection = server_with_session
    received = []
    session.on_uni_stream { |stream| received << stream }
    receive(server, connection, 6, varint(Session::WT_STREAM_UNI))
    receive_fin(server, connection, 6, varint(0) + "hello")

    assert_equal "hello", received.fetch(0).read
    assert_nil received.fetch(0).read
  end

  def test_existing_uni_stream_payload_is_not_a_session_prefix
    server, connection = server_with_session
    received = []
    session.on_uni_stream { |stream| received << stream }
    receive(server, connection, 6, varint(Session::WT_STREAM_UNI) + varint(0) + "first")
    receive(server, connection, 6, "second")

    assert_equal ["first", "second"], [received.fetch(0).read, received.fetch(0).read]
  end

  def test_late_data_after_session_close_never_becomes_http
    server, connection = server_with_session
    receive(server, connection, 4, bidi_payload("first"))
    session.notify_close
    dispatched = []
    server.stub(:dispatch_request, ->(*) { dispatched << true }) do
      receive(server, connection, 4, http3_request)
      receive_fin(server, connection, 4, http3_request)
    end

    assert_empty dispatched
  end

  def test_connection_teardown_survives_session_and_connection_callback_errors
    server, connection = server_with_session
    first = session
    second = build_session(connection, stream_id: 8)
    registry = server.instance_variable_get(:@webtransport)
    registry.for(connection.handle).register(second)
    first.on_close { raise "session callback failed" }
    notified = false
    second.on_close { notified = true }
    connection.streams[4] = Object.new
    server.on_connection_closed { raise "connection callback failed" }
    closed_handles = []

    Quicsilver.stub(:close_server_connection, ->(handle) { closed_handles << handle }) do
      error = assert_raises(RuntimeError) do
        server.handle_stream_event([connection.handle, 0], 0,
          Quicsilver::Server::STREAM_EVENT_CONNECTION_CLOSED, "".b, false)
      end
      assert_equal "connection callback failed", error.message
    end

    assert first.closed?
    assert second.closed?
    assert notified
    assert_empty connection.streams
    assert_nil server.connections[connection.handle]
    assert_equal 0, registry.connection_count
    assert_equal [connection.handle], closed_handles
    assert_includes @log.string, "session callback failed"
  end

  def receive(server, connection, stream_id, payload)
    raw = [99_000 + stream_id].pack("Q") + payload
    server.handle_stream_event([connection.handle, 0], stream_id,
      Quicsilver::Server::STREAM_EVENT_RECEIVE, raw, false)
  end

  private

  attr_reader :session

  def setup
    @log = StringIO.new
    @previous_logger = Quicsilver.logger
    Quicsilver.logger = Logger.new(@log)
  end

  def teardown
    Quicsilver.logger = @previous_logger
  end

  def server_with_session
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    server = Quicsilver::Server.new(find_available_port, server_configuration: config)

    connection_handle = 12_345
    connection = Quicsilver::Transport::Connection.new(connection_handle, [connection_handle, 0])
    server.connections[connection_handle] = connection

    @session = build_session(connection)
    server.instance_variable_get(:@webtransport).for(connection_handle).register(@session)

    [server, connection]
  end

  # RECEIVE_FIN with no preceding RECEIVE: the whole stream in one event.
  def receive_fin(server, connection, stream_id, payload)
    raw = [99_000 + stream_id].pack("Q") + payload
    server.handle_stream_event(
      [connection.handle, 0], stream_id,
      Quicsilver::Server::STREAM_EVENT_RECEIVE_FIN, raw, false
    )
  end

  def accept_stream(server, connection, stream_id)
    receive_fin(server, connection, stream_id, bidi_payload(%({"type":"reaction"})))
    session.stream(stream_id)
  end

  def stop_sending(server, connection, stream_id, error_code)
    raw = [99_000 + stream_id].pack("Q") + [error_code].pack("Q")
    server.handle_stream_event(
      [connection.handle, 0], stream_id,
      Quicsilver::Server::STREAM_EVENT_STOP_SENDING, raw, false
    )
  end

  def bidi_payload(data, session_id: SESSION_ID)
    varint(Session::WT_STREAM_BIDI) + varint(session_id) + data
  end

  def http3_request
    Quicsilver::Protocol::RequestEncoder.new(method: "GET", path: "/", headers: {}).encode
  end

  def varint(value) = Quicsilver::Protocol.encode_varint(value)

  def build_session(connection, stream_id: SESSION_ID)
    stream = Quicsilver::Transport::InboundStream.new(stream_id)
    stream.stream_handle = 99_999

    session = Session.new(
      connection: connection,
      stream: stream,
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "localhost", ":path" => "/transports/drop"
      }
    )
    session.stub(:accept!, nil) { }
    session.instance_variable_set(:@accepted, true)
    session.instance_variable_set(:@open, true)
    session
  end
end
