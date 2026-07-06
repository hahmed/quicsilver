# frozen_string_literal: true

require "test_helper"

class WebTransportSessionTest < Minitest::Test

  # === Session lifecycle ===

  def test_session_exposes_request_context
    session = build_session(
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "example.com:3000",
        ":path" => "/cable", "origin" => "https://example.com"
      }
    )

    assert_equal "/cable", session.path
    assert_equal "example.com:3000", session.authority
    assert_equal "https://example.com", session.headers["origin"]
  end

  def test_session_not_open_before_accept
    session = build_session
    refute session.open?
  end

  def test_send_datagram_raises_before_accept
    session = build_session
    assert_raises(RuntimeError) { session.send_datagram("data") }
  end

  def test_close_makes_session_not_open
    session = build_session_accepted
    assert session.open?
    session.close
    refute session.open?
  end

  def test_close_with_error_code_and_reason
    session = build_session_accepted
    session.close(code: 42, reason: "maintenance")
    refute session.open?
  end

  def test_close_truncates_long_reason
    session = build_session_accepted
    long_reason = "x" * 2000
    session.close(code: 1, reason: long_reason)
    refute session.open?
  end

  def test_close_closes_all_streams
    session = build_session_accepted
    stream1 = session.add_stream(99999, 4)
    stream2 = session.add_stream(99999, 8)

    session.close
    refute stream1.open?
    refute stream2.open?
  end

  def test_notify_close_invokes_close_callback
    session = build_session
    closed = false

    session.on_close { closed = true }
    session.notify_close

    assert closed
  end

  # === Datagrams ===

  def test_receive_datagram_invokes_callback
    session = build_session
    received = []

    session.on_datagram { |data| received << data }
    session.receive_datagram("hello")

    assert_equal ["hello"], received
  end

  def test_late_datagram_after_close_does_not_raise
    session = build_session
    session.notify_close

    session.receive_datagram("late")
  end

  # === Bidi streams ===

  def test_add_stream_invokes_stream_callback
    session = build_session
    accepted = []

    session.on_stream { |stream| accepted << stream }
    added = session.add_stream(99999, 4)

    assert_equal [added], accepted
    assert_kind_of Quicsilver::Server::WebTransportStream, added
  end

  def test_late_stream_after_close_does_not_raise
    session = build_session
    session.notify_close

    stream = session.add_stream(99999, 4)
    assert_kind_of Quicsilver::Server::WebTransportStream, stream
  end

  def test_stream_accessor_returns_stream_by_id
    session = build_session
    session.add_stream(99999, 4)
    assert_equal 4, session.stream(4).stream_id
    assert_nil session.stream(999)
  end

  def test_remove_stream_closes_and_removes
    session = build_session
    stream = session.add_stream(99999, 4)

    session.remove_stream(4)
    refute stream.open?
    assert_nil session.stream(4)
  end

  # === Uni streams ===

  def test_add_uni_stream_invokes_uni_stream_callback
    session = build_session
    accepted = []

    session.on_uni_stream { |stream| accepted << stream }
    added = session.add_uni_stream(99999, 12)

    assert_equal [added], accepted
    assert_kind_of Quicsilver::Server::WebTransportStream, added
  end

  def test_late_uni_stream_after_close_does_not_raise
    session = build_session
    session.notify_close

    stream = session.add_uni_stream(99999, 12)
    assert_kind_of Quicsilver::Server::WebTransportStream, stream
  end

  def test_incoming_uni_stream_is_receive_only
    session = build_session
    wt_stream = session.add_uni_stream(99999, 12)

    assert_raises(RuntimeError) { wt_stream.write("nope") }
  end

  # === Protocol detection ===

  def test_parse_stream_prefix_extracts_session_id_and_data
    session_id = 4
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(session_id) +
             "payload"

    id, initial_data = Quicsilver::Server::WebTransportSession.parse_stream_prefix(prefix)
    assert_equal 4, id
    assert_equal "payload", initial_data
  end

  def test_parse_stream_prefix_rejects_missing_bidi_type
    prefix = Quicsilver::Protocol.encode_varint(4) + "payload"

    assert_nil Quicsilver::Server::WebTransportSession.parse_stream_prefix(prefix)
  end

  def test_parse_uni_stream_data_extracts_session_id
    payload = Quicsilver::Protocol.encode_varint(4) + "hello"
    session_id, initial_data = Quicsilver::Server::WebTransportSession.parse_uni_stream_data(payload)

    assert_equal 4, session_id
    assert_equal "hello", initial_data
  end

  # === Capsules ===

  def test_receive_connect_data_handles_close_session_capsule
    session = build_session
    session.instance_variable_get(:@stream).expect(:send, true, [String], fin: false)
    session.accept!
    closed = false
    capsule = close_session_capsule(code: 7, reason: "bye")

    session.on_close { closed = true }
    session.receive_connect_data(capsule)

    refute session.open?
    assert closed
  end

  def test_receive_connect_data_buffers_partial_capsule
    session = build_session
    session.instance_variable_get(:@stream).expect(:send, true, [String], fin: false)
    session.accept!
    closed = false
    capsule = close_session_capsule(code: 7, reason: "bye")

    session.on_close { closed = true }
    session.receive_connect_data(capsule.byteslice(0, 2))
    assert session.open?
    refute closed

    session.receive_connect_data(capsule.byteslice(2..-1))
    refute session.open?
    assert closed
  end

  # === Class methods (routing) ===

  def test_accept_stream_routes_to_correct_session
    session = build_session
    sessions = { 0 => session }
    accepted = []
    session.on_stream { |stream| accepted << stream }

    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(0)

    result = Quicsilver::Server::WebTransportSession.accept_stream(sessions, 8, 99999, prefix)
    assert_kind_of Quicsilver::Server::WebTransportStream, result
    assert_equal [result], accepted
  end

  def test_accept_stream_makes_initial_data_available_to_callback
    session = build_session
    sessions = { 0 => session }
    received = []
    session.on_stream { |stream| stream.on_data { |data| received << data } }
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(0) +
             "hello"

    result = Quicsilver::Server::WebTransportSession.accept_stream(sessions, 8, 99999, prefix)

    assert_kind_of Quicsilver::Server::WebTransportStream, result
    assert_equal ["hello"], received
  end

  def test_accept_stream_ignores_unknown_session
    sessions = {}
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(999)

    result = Quicsilver::Server::WebTransportSession.accept_stream(sessions, 8, 99999, prefix)
    assert_nil result
  end

  private

  def close_session_capsule(code:, reason:)
    payload = [code].pack("N") + reason.b
    Quicsilver::Protocol.encode_varint(Quicsilver::Server::WebTransportSession::WT_CLOSE_SESSION) +
      Quicsilver::Protocol.encode_varint(payload.bytesize) +
      payload
  end

  def build_session(headers: nil)
    headers ||= {
      ":method" => "CONNECT", ":protocol" => "webtransport",
      ":scheme" => "https", ":authority" => "localhost:4433", ":path" => "/cable"
    }
    connection = Minitest::Mock.new
    stream = Minitest::Mock.new
    stream.expect(:stream_id, 0)
    stream.expect(:stream_handle, 99999)

    Quicsilver::Server::WebTransportSession.new(
      connection: connection, stream: stream, headers: headers
    )
  end

  def build_session_accepted
    session = build_session
    stream_mock = session.instance_variable_get(:@stream)
    stream_mock.expect(:send, true, [String], fin: false)  # accept! headers
    stream_mock.expect(:send, true, [String], fin: false)  # close capsule
    stream_mock.expect(:reset, true, [Integer])            # stream reset
    session.accept!
    session
  end
end
