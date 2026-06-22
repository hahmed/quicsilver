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
    # Should not raise — reason gets truncated to 1024 bytes
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

  # === Datagrams ===

  def test_read_datagram_receives_data
    session = build_session_accepted
    session.receive_datagram("hello")
    assert_equal "hello", session.read_datagram
  end

  def test_read_datagram_returns_nil_when_session_closes
    session = build_session_accepted
    session.close
    assert_nil session.read_datagram
  end

  def test_datagrams_dropped_tracks_full_datagram_queue
    session = build_session_accepted
    queue = Quicsilver::Transport::DatagramQueue.new(max_length: 1)
    session.instance_variable_set(:@datagram_queue, queue)

    session.receive_datagram("first")
    session.receive_datagram("second")

    assert_equal 1, session.datagrams_dropped
    assert_equal "first", session.read_datagram
  end

  def test_each_datagram_yields_until_session_closes
    session = build_session_accepted
    session.receive_datagram("one")
    session.receive_datagram("two")
    session.close

    assert_equal ["one", "two"], session.each_datagram.to_a
  end

  def test_each_datagram_enumerator_has_unknown_size
    assert_nil build_session.each_datagram.size
  end

  # === Bidi streams ===

  def test_accept_stream_receives_bidi_stream
    session = build_session
    added = session.add_stream(99999, 4)
    accepted = session.accept_stream
    assert_same added, accepted
    assert_kind_of Quicsilver::Server::WebTransportStream, accepted
  end

  def test_accept_stream_returns_nil_when_session_closes
    session = build_session_accepted
    session.close
    assert_nil session.accept_stream
  end

  def test_stream_accessor_returns_stream_by_id
    session = build_session
    session.add_stream(99999, 4)
    assert_equal 4, session.stream(4).stream_id
    assert_nil session.stream(999)
  end

  def test_each_stream_yields_until_session_closes
    session = build_session_accepted
    first = session.add_stream(99999, 4)
    second = session.add_stream(99999, 8)
    session.close

    assert_equal [first, second], session.each_stream.to_a
  end

  def test_each_stream_enumerator_has_unknown_size
    assert_nil build_session.each_stream.size
  end

  def test_remove_stream_closes_and_removes
    session = build_session
    stream = session.add_stream(99999, 4)

    session.remove_stream(4)
    refute stream.open?
    assert_nil session.stream(4)
  end

  # === Uni streams ===

  def test_accept_uni_stream_receives_uni_stream
    session = build_session
    added = session.add_uni_stream(99999, 12)
    accepted = session.accept_uni_stream
    assert_same added, accepted
    assert_kind_of Quicsilver::Server::WebTransportStream, accepted
  end

  def test_accept_uni_stream_returns_nil_when_session_closes
    session = build_session_accepted
    session.close
    assert_nil session.accept_uni_stream
  end

  def test_incoming_uni_stream_is_receive_only
    session = build_session
    wt_stream = session.add_uni_stream(99999, 12)

    assert_raises(RuntimeError) { wt_stream.write("nope") }
  end

  def test_each_uni_stream_yields_until_session_closes
    session = build_session_accepted
    first = session.add_uni_stream(99999, 12)
    second = session.add_uni_stream(99999, 16)
    session.close

    assert_equal [first, second], session.each_uni_stream.to_a
  end

  def test_each_uni_stream_enumerator_has_unknown_size
    assert_nil build_session.each_uni_stream.size
  end

  # === Protocol detection ===

  def test_webtransport_stream_detects_bidi_prefix
    prefix = Quicsilver::Protocol.encode_varint(0x41) + Quicsilver::Protocol.encode_varint(0)
    assert Quicsilver::Server::WebTransportSession.webtransport_stream?(prefix)
  end

  def test_webtransport_stream_detects_uni_prefix
    prefix = Quicsilver::Protocol.encode_varint(0x54) + Quicsilver::Protocol.encode_varint(0)
    assert Quicsilver::Server::WebTransportSession.webtransport_stream?(prefix)
  end

  def test_webtransport_stream_rejects_headers_frame
    data = Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::FRAME_HEADERS) + "\x00"
    refute Quicsilver::Server::WebTransportSession.webtransport_stream?(data)
  end

  def test_parse_stream_prefix_extracts_session_id_and_data
    session_id = 4
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(session_id) +
             "payload"

    id, initial_data = Quicsilver::Server::WebTransportSession.parse_stream_prefix(prefix)
    assert_equal 4, id
    assert_equal "payload", initial_data
  end

  def test_parse_uni_stream_data_extracts_session_id
    payload = Quicsilver::Protocol.encode_varint(4) + "hello"
    session_id, initial_data = Quicsilver::Server::WebTransportSession.parse_uni_stream_data(payload)

    assert_equal 4, session_id
    assert_equal "hello", initial_data
  end

  # === Class methods (routing) ===

  def test_accept_stream_routes_to_correct_session
    session = build_session
    sessions = { 0 => session }
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(0)

    routed = Quicsilver::Server::WebTransportSession.accept_stream(sessions, 8, 99999, prefix)
    assert_kind_of Quicsilver::Server::WebTransportStream, routed
    assert_same routed, session.accept_stream
  end

  def test_accept_stream_ignores_unknown_session
    sessions = {}
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(999)

    result = Quicsilver::Server::WebTransportSession.accept_stream(sessions, 8, 99999, prefix)
    assert_nil result
  end

  def test_find_stream_across_sessions
    s1 = build_session
    s2 = build_session
    s2.add_stream(99999, 8)
    sessions = { 0 => s1, 4 => s2 }

    found = Quicsilver::Server::WebTransportSession.find_stream(sessions, 8)
    assert_equal 8, found.stream_id
  end

  def test_find_stream_returns_nil_when_not_found
    sessions = { 0 => build_session }
    assert_nil Quicsilver::Server::WebTransportSession.find_stream(sessions, 999)
  end

  def test_find_session_for_stream
    s1 = build_session
    s2 = build_session
    s2.add_stream(99999, 8)
    sessions = { 0 => s1, 4 => s2 }

    found = Quicsilver::Server::WebTransportSession.find_session_for_stream(sessions, 8)
    assert_equal s2, found
  end

  private

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
