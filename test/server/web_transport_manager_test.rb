# frozen_string_literal: true

require "test_helper"

class WebTransportManagerTest < Minitest::Test
  def test_register_and_lookup_session
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)

    manager.register(session)

    assert_same session, manager.session(0)
  end

  def test_unregister_removes_and_returns_session
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)

    manager.register(session)

    assert_same session, manager.unregister(0)
    assert_nil manager.session(0)
  end

  def test_sessions_for_connection_returns_matching_sessions
    manager = Quicsilver::Server::WebTransportManager.new
    connection = Object.new
    other_connection = Object.new
    session = build_session(stream_id: 0, connection: connection)
    other_session = build_session(stream_id: 4, connection: other_connection)

    manager.register(session)
    manager.register(other_session)

    assert_equal({ 0 => session }, manager.sessions_for_connection(connection))
  end

  def test_active_stream_finds_stream_across_sessions
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)
    stream = session.add_stream(99999, 4)

    manager.register(session)

    assert_same stream, manager.active_stream(4)
  end

  def test_session_for_stream_finds_owner
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)
    session.add_stream(99999, 4)

    manager.register(session)

    assert_same session, manager.session_for_stream(4)
  end

  def test_shutdown_stream_removes_stream_from_owner
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)
    stream = session.add_stream(99999, 4)

    manager.register(session)

    assert manager.shutdown_stream(4)
    assert_nil session.stream(4)
    refute stream.open?
  end

  def test_open_session_for_connection
    manager = Quicsilver::Server::WebTransportManager.new
    connection = Object.new
    session = build_session(stream_id: 0, connection: connection)
    accept_session(session)

    manager.register(session)

    assert_same session, manager.open_session_for_connection(connection)
  end

  def test_pending_payload_buffers_incomplete_bidi_prefix
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 64)
    accept_session(session)
    manager.register(session)

    prefix = Quicsilver::Protocol.encode_varint(Quicsilver::Server::WebTransportSession::WT_STREAM_BIDI) +
             Quicsilver::Protocol.encode_varint(64) +
             "hello"

    assert_nil manager.pending_payload(4, 99999, prefix.byteslice(0, 1))
    assert manager.pending_stream?(4)
    assert_equal prefix, manager.pending_payload(4, 99999, prefix.byteslice(1..-1))
    refute manager.pending_stream?(4)
  end

  def test_bidi_stream_requires_registered_open_session
    manager = Quicsilver::Server::WebTransportManager.new
    prefix = Quicsilver::Protocol.encode_varint(Quicsilver::Server::WebTransportSession::WT_STREAM_BIDI) +
             Quicsilver::Protocol.encode_varint(0)

    refute manager.bidi_stream?(prefix)

    session = build_session(stream_id: 0)
    accept_session(session)
    manager.register(session)

    assert manager.bidi_stream?(prefix)
  end

  def test_accept_bidi_stream_routes_to_session
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)
    accepted = []
    session.on_stream { |stream| accepted << stream }
    manager.register(session)

    payload = Quicsilver::Protocol.encode_varint(Quicsilver::Server::WebTransportSession::WT_STREAM_BIDI) +
              Quicsilver::Protocol.encode_varint(0) +
              "hello"

    stream = manager.accept_bidi_stream(4, 99999, payload)

    assert_equal [stream], accepted
  end

  def test_accept_bidi_stream_returns_nil_for_unknown_session
    manager = Quicsilver::Server::WebTransportManager.new
    payload = Quicsilver::Protocol.encode_varint(Quicsilver::Server::WebTransportSession::WT_STREAM_BIDI) +
              Quicsilver::Protocol.encode_varint(99) +
              "hello"

    assert_nil manager.accept_bidi_stream(4, 99999, payload)
  end

  def test_accept_uni_stream_routes_to_session
    manager = Quicsilver::Server::WebTransportManager.new
    session = build_session(stream_id: 0)
    accepted = []
    session.on_uni_stream { |stream| accepted << stream }
    manager.register(session)

    payload = Quicsilver::Protocol.encode_varint(0) + "hello"

    stream = manager.accept_uni_stream(8, 99999, payload)

    assert_equal [stream], accepted
  end

  def test_accept_uni_stream_returns_nil_for_unknown_session
    manager = Quicsilver::Server::WebTransportManager.new
    payload = Quicsilver::Protocol.encode_varint(99) + "hello"

    assert_nil manager.accept_uni_stream(8, 99999, payload)
  end

  private

  def accept_session(session)
    session.instance_variable_get(:@stream).expect(:send, true, [String], fin: false)
    session.accept!
  end

  def build_session(stream_id:, connection: Object.new)
    stream = Minitest::Mock.new
    stream.expect(:stream_id, stream_id)
    stream.expect(:stream_handle, 99999)

    Quicsilver::Server::WebTransportSession.new(
      connection: connection,
      stream: stream,
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "localhost", ":path" => "/wt"
      }
    )
  end
end
