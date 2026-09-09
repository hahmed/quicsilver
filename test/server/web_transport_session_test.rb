# frozen_string_literal: true

require "test_helper"

class WebTransportSessionTest < Minitest::Test
  Session = Quicsilver::Server::WebTransportSession


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

  def test_send_datagram_prefixes_payload_with_quarter_stream_id
    connection_data = Object.new
    connection = Minitest::Mock.new
    connection.expect(:data, connection_data)
    session = build_session(connection: connection)
    accept_webtransport_session(session)

    expected = Quicsilver::Protocol::Datagram.encode(session.stream_id, "hello")
    assert_datagram_sent(connection_data, expected) do
      session.send_datagram("hello")
    end

    connection.verify
  end

  def test_send_datagram_raises_after_close
    session = build_session_accepted
    session.close

    assert_raises(RuntimeError) { session.send_datagram("hello") }
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

  # draft-16 §6: "Senders that truncate an application-supplied message MUST do
  # so at a UTF-8 character boundary." A receiver seeing invalid UTF-8 MUST
  # reset the stream with H3_MESSAGE_ERROR, so cutting mid-character makes a
  # conformant peer tear down our stream.

  # A short or absent payload is a clean close: code 0, empty reason (§6).

  def test_parse_close_payload_reads_code_and_reason
    info = Session.parse_close_payload([7].pack("N") + "bye")

    assert_equal 7, info.code
    assert_equal "bye", info.reason
  end

  def test_parse_close_payload_handles_a_code_with_no_reason
    info = Session.parse_close_payload([7].pack("N"))

    assert_equal 7, info.code
    assert_equal "", info.reason
  end

  def test_parse_close_payload_handles_an_empty_payload
    info = Session.parse_close_payload("")

    assert_equal 0, info.code
    assert_equal "", info.reason
  end

  def test_parse_close_payload_handles_a_truncated_code
    info = Session.parse_close_payload("\x00\x07".b)

    assert_equal 0, info.code
  end

  def test_parse_close_payload_tags_the_reason_as_utf8
    info = Session.parse_close_payload([0].pack("N") + "完了".b)

    assert_equal "完了", info.reason
    assert_equal Encoding::UTF_8, info.reason.encoding
  end

  def test_close_payload_round_trips
    info = Session.parse_close_payload(Session.build_close_payload(7, "bye"))

    assert_equal 7, info.code
    assert_equal "bye", info.reason
  end

  def test_truncate_reason_leaves_short_messages_alone
    assert_equal "Go \u{1F680}", Session.truncate_reason("Go \u{1F680}", 100)
  end

  def test_truncate_reason_keeps_a_character_that_exactly_fits
    assert_equal "Go \u{1F680}", Session.truncate_reason("Go \u{1F680}", 7)
  end

  def test_truncate_reason_drops_a_character_that_would_be_split
    # The rocket is 4 bytes, so limits 3..6 cannot include it.
    (3..6).each do |limit|
      assert_equal "Go ", Session.truncate_reason("Go \u{1F680}", limit),
        "failed at limit #{limit}"
    end
  end

  def test_truncate_reason_never_produces_invalid_utf8
    reason = "a" * 1022 + "\u{1F680}"
    truncated = Session.truncate_reason(reason, 1024)

    assert truncated.valid_encoding?
    assert_operator truncated.bytesize, :<=, 1024
  end

  def test_truncate_reason_respects_the_spec_limit_by_default
    truncated = Session.truncate_reason("x" * 2000)

    assert_equal Session::MAX_CLOSE_MESSAGE_LENGTH, truncated.bytesize
  end

  def test_close_closes_all_streams
    session = build_session_accepted
    stream1 = session.add_stream(99999, 4)
    stream2 = session.add_stream(99999, 8)

    session.close
    refute stream1.open?
    refute stream2.open?
  end

  def test_child_callback_failure_does_not_interrupt_session_termination
    session = build_session
    first = session.add_stream(99998, 4)
    second = session.add_uni_stream(99999, 6)
    first.on_close { raise "application close failed" }
    closed = false
    session.on_close { closed = true }
    cancelled = []

    Quicsilver.stub(:stream_abort, ->(*args) { cancelled << args }) do
      assert_raises(RuntimeError) { session.notify_close }
      session.notify_close
    end

    assert_equal [[99998, 0x170d7b68], [99999, 0x170d7b68]], cancelled
    refute second.open?
    assert closed
    assert_nil session.stream(4)
    assert_nil session.stream(6)
  end

  def test_notify_close_invokes_close_callback
    session = build_session
    closed = false

    session.on_close { closed = true }
    session.notify_close

    assert closed
  end

  def test_notify_close_is_idempotent
    session = build_session
    call_count = 0

    session.on_close { call_count += 1 }
    session.notify_close
    session.notify_close

    assert_equal 1, call_count
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
    accept_webtransport_session(session)
    closed = false
    capsule = close_session_capsule(code: 7, reason: "bye")

    session.on_close { closed = true }
    session.receive_connect_data(capsule)

    refute session.open?
    assert closed
  end

  def test_receive_connect_data_buffers_partial_capsule
    session = build_session
    accept_webtransport_session(session)
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

  # === close code and reason (draft-16 §6) ===
  #
  # The peer's WT_CLOSE_SESSION capsule carries a 32-bit code and a UTF-8
  # reason. We decoded both and dropped them, so an application could not tell
  # a clean close from an error, or the peer hanging up from us closing.

  def test_close_capsule_reports_the_code_and_reason
    session = build_session
    accept_webtransport_session(session)
    info = nil

    session.on_close { |close_info| info = close_info }
    session.receive_connect_data(close_capsule(7, "going away"))

    assert_equal 7, info.code
    assert_equal "going away", info.reason
  end

  def test_close_capsule_without_a_reason_reports_an_empty_string
    session = build_session
    accept_webtransport_session(session)
    info = nil

    session.on_close { |close_info| info = close_info }
    session.receive_connect_data(close_capsule(3, ""))

    assert_equal 3, info.code
    assert_equal "", info.reason
  end

  # §6: a clean CONNECT stream close is equivalent to a capsule with code 0 and
  # an empty reason.
  def test_a_clean_close_reports_code_zero
    session = build_session
    accept_webtransport_session(session)
    info = nil

    session.on_close { |close_info| info = close_info }
    session.notify_close

    assert_equal 0, info.code
    assert_equal "", info.reason
  end

  # Existing handlers take no arguments; they must keep working.
  def test_close_handlers_that_ignore_the_argument_still_work
    session = build_session
    accept_webtransport_session(session)
    closed = false

    session.on_close { closed = true }
    session.receive_connect_data(close_capsule(7, "bye"))

    assert closed
  end

  def test_close_capsule_preserves_a_utf8_reason
    session = build_session
    accept_webtransport_session(session)
    info = nil

    session.on_close { |close_info| info = close_info }
    session.receive_connect_data(close_capsule(0, "完了"))

    assert_equal "完了", info.reason
  end

  # The wire format cannot say who closed; applications need it for reconnect.

  def test_a_peer_close_is_reported_as_remote
    session = build_session
    accept_webtransport_session(session)
    info = nil

    session.on_close { |close_info| info = close_info }
    session.receive_connect_data(close_capsule(7, "bye"))

    assert info.remote?
  end

  def test_closing_ourselves_is_reported_as_local
    session = session_with(RecordingConnectStream.new)
    session.accept!
    info = nil

    session.on_close { |close_info| info = close_info }
    session.close(code: 3, reason: "shutting down")

    assert info.local?
    assert_equal 3, info.code
    assert_equal "shutting down", info.reason
  end

  # === WT_DRAIN_SESSION (draft-16 §4.7) ===
  #
  #   After sending or receiving either a WT_DRAIN_SESSION capsule or a HTTP/3
  #   GOAWAY frame, an endpoint MAY continue using the session ... The signal
  #   is intended for the application, which is expected to attempt to
  #   gracefully terminate the session as soon as possible.
  #
  # So it is advisory: the session stays usable and the app decides when to go.

  def test_drain_capsule_notifies_the_application
    session = build_session
    accept_webtransport_session(session)
    drained = false

    session.on_drain { drained = true }
    session.receive_connect_data(drain_capsule)

    assert drained
  end

  def test_drain_capsule_leaves_the_session_open
    session = build_session
    accept_webtransport_session(session)

    session.receive_connect_data(drain_capsule)

    assert session.open?
    assert session.accepts_new_streams?, "draining is advisory, not a close"
  end

  def test_drain_capsule_does_not_close_the_session
    session = build_session
    accept_webtransport_session(session)
    closed = false

    session.on_close { closed = true }
    session.receive_connect_data(drain_capsule)

    refute closed
  end

  def test_drain_capsule_without_a_handler_is_harmless
    session = build_session
    accept_webtransport_session(session)

    session.receive_connect_data(drain_capsule)

    assert session.open?
  end

  def test_drain_sends_an_empty_capsule
    stream = RecordingConnectStream.new
    session = session_with(stream)
    session.accept!

    session.drain!

    assert_includes stream.writes, drain_capsule
  end

  def test_drain_leaves_the_session_usable
    session = session_with(RecordingConnectStream.new)
    session.accept!

    session.drain!

    assert session.open?
    assert session.accepts_new_streams?
  end

  def test_receive_connect_data_ignores_unknown_capsule
    session = build_session
    accept_webtransport_session(session)
    closed = false
    capsule = Quicsilver::Protocol::Capsule.encode(0x2a, "ignored")

    session.on_close { closed = true }
    session.receive_connect_data(capsule)

    assert session.open?
    refute closed
  end

  def test_receive_connect_data_handles_multiple_capsules
    session = build_session
    accept_webtransport_session(session)
    closed = false
    capsules = Quicsilver::Protocol::Capsule.encode(0x2a, "ignored") +
      close_session_capsule(code: 7, reason: "bye")

    session.on_close { closed = true }
    session.receive_connect_data(capsules)

    refute session.open?
    assert closed
  end

  def test_receive_connect_data_handles_empty_close_session_capsule
    session = build_session
    accept_webtransport_session(session)
    closed = false
    capsule = Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Server::WebTransportSession::WT_CLOSE_SESSION,
      ""
    )

    session.on_close { closed = true }
    session.receive_connect_data(capsule)

    refute session.open?
    assert closed
  end

  def test_receive_connect_data_closes_session_when_capsule_is_too_large
    session = build_session
    accept_webtransport_session(session)
    expect_capsule_error_reset(session)
    closed = false
    capsule = Quicsilver::Protocol::Capsule.encode(0x2a, "hello")

    session.on_close { closed = true }
    parser = Quicsilver::Protocol::Capsule.method(:parse)
    Quicsilver::Protocol::Capsule.stub(:parse, ->(buffer, max_payload_size: Quicsilver::Protocol::Capsule::MAX_PAYLOAD_SIZE) {
      parser.call(buffer, max_payload_size: 4)
    }) do
      session.receive_connect_data(capsule)
    end

    refute session.open?
    assert closed
  end

  def test_receive_connect_fin_closes_session_when_capsule_is_truncated
    session = build_session
    accept_webtransport_session(session)
    expect_capsule_error_reset(session)
    closed = false
    capsule = close_session_capsule(code: 7, reason: "bye")

    session.on_close { closed = true }
    session.receive_connect_fin(capsule.byteslice(0, 2))

    refute session.open?
    assert closed
  end

  def test_receive_connect_fin_closes_session_after_complete_capsules
    session = build_session
    accept_webtransport_session(session)
    closed = false
    capsule = Quicsilver::Protocol::Capsule.encode(0x2a, "ignored")

    session.on_close { closed = true }
    session.receive_connect_fin(capsule)

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

  def test_accept_stream_makes_initial_data_available_to_reader
    session = build_session
    sessions = { 0 => session }
    received = []
    session.on_stream { |stream| received << stream }
    prefix = Quicsilver::Protocol.encode_varint(0x41) +
             Quicsilver::Protocol.encode_varint(0) +
             "hello"

    result = Quicsilver::Server::WebTransportSession.accept_stream(sessions, 8, 99999, prefix)

    assert_kind_of Quicsilver::Server::WebTransportStream, result
    assert_equal [result], received
    assert_equal "hello", result.read
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
    Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Server::WebTransportSession::WT_CLOSE_SESSION,
      payload
    )
  end

  def assert_datagram_sent(expected_connection_data, expected_payload)
    Quicsilver.stub(:datagram_send, ->(connection_data, payload) {
      assert_same expected_connection_data, connection_data
      assert_equal expected_payload, payload
      true
    }) do
      yield
    end
  end

  def build_session(headers: nil, connection: Minitest::Mock.new)
    headers ||= {
      ":method" => "CONNECT", ":protocol" => "webtransport",
      ":scheme" => "https", ":authority" => "localhost:4433", ":path" => "/cable"
    }
    stream = Minitest::Mock.new
    stream.expect(:stream_id, 0)
    stream.expect(:stream_handle, 99999)

    Quicsilver::Server::WebTransportSession.new(
      connection: connection, stream: stream, headers: headers
    )
  end

  def build_session_accepted
    session = build_session
    expect_successful_connect_response(session)
    expect_close_session_capsule(session)
    expect_stream_reset(session)
    session.accept!
    session
  end

  def accept_webtransport_session(session)
    expect_successful_connect_response(session)
    session.accept!
  end

  def expect_successful_connect_response(session)
    session_stream(session).expect(:send, true, [String], fin: false)
  end

  def drain_capsule
    Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Protocol::WebTransport::DRAIN_SESSION_CAPSULE, ""
    )
  end

  def close_capsule(code, reason)
    Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Protocol::WebTransport::CLOSE_SESSION_CAPSULE,
      [code].pack("N") + reason.b
    )
  end

  # Records what reaches the CONNECT stream, so tests assert on the bytes the
  # peer would receive rather than on mock expectations.
  class RecordingConnectStream
    attr_reader :writes

    def initialize = @writes = []

    def send(data, fin: false) = @writes << data
    def reset(code = nil) = nil
    def stream_id = 0
    def stream_handle = 99_999
  end

  def session_with(stream)
    Quicsilver::Server::WebTransportSession.new(
      connection: Object.new,
      stream: stream,
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "localhost:4433", ":path" => "/cable"
      }
    )
  end

  def expect_close_session_capsule(session)
    session_stream(session).expect(:send, true, [String], fin: false)
  end

  def expect_stream_reset(session)
    session_stream(session).expect(:reset, true, [Integer])
  end

  def expect_capsule_error_reset(session)
    session_stream(session).expect(:reset, true, [Quicsilver::Protocol::H3_DATAGRAM_ERROR])
  end

  def session_stream(session)
    session.instance_variable_get(:@stream)
  end
end
