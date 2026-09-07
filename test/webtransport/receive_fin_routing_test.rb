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
    server.instance_variable_get(:@webtransport).register(@session)

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

  def bidi_payload(data, session_id: SESSION_ID)
    varint(Session::WT_STREAM_BIDI) + varint(session_id) + data
  end

  def http3_request
    Quicsilver::Protocol::RequestEncoder.new(method: "GET", path: "/", headers: {}).encode
  end

  def varint(value) = Quicsilver::Protocol.encode_varint(value)

  def build_session(connection)
    stream = Quicsilver::Transport::InboundStream.new(SESSION_ID)
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
