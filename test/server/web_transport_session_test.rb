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
    connection = Struct.new(:data).new(connection_data)
    session = build_session(connection: connection)
    session.accept!

    expected = Quicsilver::Protocol::Datagram.encode(session.stream_id, "hello")
    assert_datagram_sent(connection_data, expected) do
      session.send_datagram("hello")
    end
  end

  def test_send_datagram_raises_after_close
    session = build_session
    session.accept!
    session.close

    assert_raises(RuntimeError) { session.send_datagram("hello") }
  end

  def test_close_delivers_reason_with_fin_without_reset
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    notifications = []
    session.on_close { |info| notifications << info }

    session.close(code: 42, reason: "maintenance")
    session.close(code: 99, reason: "duplicate")

    assert_equal close_capsule(42, "maintenance"), response_body(stream)
    assert stream.finished?
    assert_nil stream.error_code
    assert_equal [42], notifications.map(&:code)
    assert_equal "maintenance", notifications.first.reason
    assert notifications.first.local?
    refute session.open?
  end

  def test_receiving_close_finishes_connect_and_preserves_peer_reason
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    notifications = []
    session.on_close { |info| notifications << info }

    session.receive_connect_data(close_capsule(7, "bye"))
    session.receive_connect_fin("")

    assert_empty response_body(stream)
    assert stream.finished?
    assert_nil stream.error_code
    assert_equal 1, notifications.size
    assert_equal 7, notifications.first.code
    assert_equal "bye", notifications.first.reason
    assert notifications.first.remote?
    assert session.closed?
  end

  def test_close_still_notifies_when_connect_send_fails
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    notifications = []
    session.on_close { |info| notifications << info }

    log = StringIO.new
    Quicsilver.stub(:logger, Logger.new(log)) do
      stream.stub(:send, ->(*) { raise IOError, "connection gone" }) do
        session.close(code: 7, reason: "bye")
      end
    end

    assert_match(/WebTransport session 0.*FIN.*IOError.*aborting CONNECT/, log.string)
    assert session.closed?
    assert_equal [7], notifications.map(&:code)
    assert_equal Quicsilver::Protocol::H3_INTERNAL_ERROR, stream.error_code
  end

  def test_receiving_close_finishes_connect_before_a_raising_callback
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    session.on_close { raise "callback failed" }

    assert_raises(RuntimeError) { session.receive_connect_data(close_capsule(7, "bye")) }

    assert_empty response_body(stream)
    assert stream.finished?
    assert session.closed?
  end

  def test_raising_close_callback_does_not_skip_trailing_data_rejection
    capsule = close_capsule(7, "bye")
    [data_frame(capsule + "x"), data_frame(capsule) + data_frame("x")].each do |wire|
      stream = RecordingConnectStream.new
      session = build_session(stream: stream)
      session.accept!
      session.on_close { raise "application callback failed" }

      error = assert_raises(RuntimeError) do
        session.receive_connect_stream_data(wire, fin: true)
      end

      assert_equal "application callback failed", error.message
      assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, stream.error_code
      assert session.closed?
    end
  end

  def test_raising_close_callback_does_not_skip_truncated_frame_rejection
    connection = RecordingConnection.new
    session = build_session(connection: connection)
    session.accept!
    session.on_close { raise "application callback failed" }
    capsule = close_capsule(7, "bye")
    wire = "\x00".b + Quicsilver::Protocol.encode_varint(capsule.bytesize + 1) + capsule

    session.receive_connect_stream_data(wire, fin: true)

    assert_equal Quicsilver::Protocol::H3_FRAME_ERROR, connection.error_code
    assert session.closed?
  end

  def test_raising_drain_callback_is_not_a_peer_frame_error
    connection = RecordingConnection.new
    session = build_session(connection: connection)
    session.accept!
    session.on_drain { raise "application callback failed" }
    wire = data_frame(drain_capsule) + data_frame("")

    assert_raises(RuntimeError) { session.receive_connect_stream_data(wire, fin: true) }

    assert_nil connection.error_code
  end

  def test_invalid_local_close_leaves_session_usable
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    [nil, -1, 1 << 32].each do |code|
      assert_raises(ArgumentError) { session.close(code: code) }
      assert session.open?
      refute session.closed?
    end
    assert_raises(ArgumentError) { session.close(reason: "\xff".b) }
    assert session.open?
    session.close(code: 7, reason: "valid")
    assert_equal close_capsule(7, "valid"), response_body(stream)
    assert stream.finished?
  end

  def test_failed_fin_and_failed_abort_still_clean_up
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    notified = false
    session.on_close { notified = true }
    stream.stub(:send, ->(*) { raise RuntimeError, "StreamSend failed" }) do
      stream.stub(:abort, ->(*) { raise IOError, "gone" }) { session.close }
    end
    assert session.closed?
    assert notified
  end

  def test_malformed_close_reasons_reset_without_fin
    ["", "\x00\x01".b, [7].pack("N") + "\xff".b, [7].pack("N") + "a" * 1025].each do |payload|
      stream = RecordingConnectStream.new
      session = build_session(stream: stream)
      session.accept!
      session.receive_connect_data(Quicsilver::Protocol::Capsule.encode(Session::WT_CLOSE_SESSION, payload))
      assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, stream.error_code
      assert_empty response_body(stream)
      refute stream.finished?
      assert session.closed?
    end
  end

  def test_maximum_valid_close_reason_is_accepted
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    info = nil
    session.on_close { |value| info = value }
    session.receive_connect_data(close_capsule(7, "a" * 1024))
    assert_equal "a" * 1024, info.reason
    assert_nil stream.error_code
  end

  def test_data_after_close_is_an_error_even_in_the_same_chunk
    [true, false].each do |together|
      stream = RecordingConnectStream.new
      session = build_session(stream: stream)
      session.accept!
      capsule = close_capsule(7, "bye")
      session.receive_connect_data(together ? capsule + "x" : capsule)
      session.receive_connect_data("x") unless together
      assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, stream.error_code
    end
  end

  def test_close_before_accept_terminates_connect_and_cannot_be_accepted_later
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.receive_connect_data(close_capsule(7, "bye"))
    assert session.closed?
    assert_equal Quicsilver::Protocol::H3_REQUEST_REJECTED, stream.error_code
    assert_raises(IOError) { session.accept! }
    assert_empty stream.bytes
  end

  def test_connect_handles_unknown_frames_and_capsules_split_across_data_frames
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    capsule = close_capsule(7, "bye")
    wire = Quicsilver::Protocol.build_frame(0x21, "ignored") +
      data_frame(capsule.byteslice(0, 3)) + data_frame(capsule.byteslice(3..))
    wire.each_byte { |byte| session.receive_connect_stream_data(byte.chr.b) }
    assert session.closed?
    assert_empty response_body(stream)
    assert stream.finished?
    assert_nil stream.error_code
  end

  def test_connect_rejects_truncated_frame_header_and_payload
    ["\x00".b, "\x00\x05x".b].each do |wire|
      stream = RecordingConnectStream.new
      connection = RecordingConnection.new
      session = build_session(connection: connection, stream: stream)
      session.accept!
      session.receive_connect_stream_data(wire, fin: true)
      assert_equal Quicsilver::Protocol::H3_FRAME_ERROR, connection.error_code
      assert session.closed?
    end
  end

  def test_fin_after_close_still_checks_the_enclosing_data_frame_length
    stream = RecordingConnectStream.new
    connection = RecordingConnection.new
    session = build_session(connection: connection, stream: stream)
    session.accept!
    capsule = close_capsule(7, "bye")
    wire = "\x00".b + Quicsilver::Protocol.encode_varint(capsule.bytesize + 1) + capsule
    session.receive_connect_stream_data(wire)
    session.receive_connect_stream_data("", fin: true)
    assert_equal Quicsilver::Protocol::H3_FRAME_ERROR, connection.error_code
  end

  def test_known_non_data_frame_on_connect_closes_connection
    connection = RecordingConnection.new
    stream = RecordingConnectStream.new
    session = build_session(connection: connection, stream: stream)
    session.accept!
    session.receive_connect_stream_data(Quicsilver::Protocol.build_headers_frame([[":status", "200"]]))
    assert_equal Quicsilver::Protocol::H3_FRAME_UNEXPECTED, connection.error_code
    assert session.closed?
  end

  def test_clean_peer_fin_finishes_response
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    info = nil
    session.on_close { |close_info| info = close_info }

    session.receive_connect_stream_data("", fin: true)
    assert_empty response_body(stream)
    assert stream.finished?
    assert session.closed?
    assert_equal 0, info.code
    assert_equal "", info.reason
    assert info.remote?
  end

  def test_close_truncates_long_reason
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    session.close(code: 1, reason: "x" * 2000)

    assert_equal close_capsule(1, "x" * 1024), response_body(stream)
    assert stream.finished?
  end

  def test_close_preserves_utf8_characters_at_the_reason_limit
    ["Go 🚀", "a" * 1020 + "🚀"].each do |reason|
      stream = RecordingConnectStream.new
      session = build_session(stream: stream)
      session.accept!
      session.close(reason: reason)

      assert_equal close_capsule(0, reason), response_body(stream)
      assert stream.finished?
    end
  end

  def test_close_drops_a_character_that_would_cross_the_reason_limit
    (1021..1023).each do |prefix_length|
      stream = RecordingConnectStream.new
      session = build_session(stream: stream)
      session.accept!
      prefix = "a" * prefix_length
      session.close(reason: prefix + "🚀")

      assert_equal close_capsule(0, prefix), response_body(stream), "prefix length #{prefix_length}"
      assert stream.finished?
    end
  end

  def test_close_closes_all_streams
    session = build_session
    session.accept!
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

  def test_receive_connect_data_buffers_partial_capsule
    session = build_session
    session.accept!
    closed = false
    capsule = close_capsule(7, "bye")

    session.on_close { closed = true }
    session.receive_connect_data(capsule.byteslice(0, 2))
    assert session.open?
    refute closed

    session.receive_connect_data(capsule.byteslice(2..-1))
    refute session.open?
    assert closed
  end

  # === close code and reason (draft-16 §6) ===

  def test_close_capsule_without_a_reason_reports_an_empty_string
    session = build_session
    session.accept!
    info = nil

    session.on_close { |close_info| info = close_info }
    session.receive_connect_data(close_capsule(3, ""))

    assert_equal 3, info.code
    assert_equal "", info.reason
  end

  # Existing handlers take no arguments; they must keep working.
  def test_close_handlers_that_ignore_the_argument_still_work
    session = build_session
    session.accept!
    closed = false

    session.on_close { closed = true }
    session.receive_connect_data(close_capsule(7, "bye"))

    assert closed
  end

  def test_close_capsule_preserves_a_utf8_reason
    session = build_session
    session.accept!
    info = nil

    session.on_close { |close_info| info = close_info }
    session.receive_connect_data(close_capsule(0, "完了"))

    assert_equal "完了", info.reason
    assert_equal Encoding::UTF_8, info.reason.encoding
    assert info.reason.valid_encoding?
  end

  # === WT_DRAIN_SESSION (draft-16 §4.7) ===
  # Drain is advisory: the application decides when to close.

  def test_peer_drain_notifies_without_closing_the_session
    session = build_session
    session.accept!
    drained = false
    closed = false
    session.on_drain { drained = true }
    session.on_close { closed = true }

    session.receive_connect_data(drain_capsule)

    assert drained
    refute closed
    assert session.open?
    assert session.accepts_new_streams?
  end

  def test_drain_capsule_without_a_handler_is_harmless
    session = build_session
    session.accept!

    session.receive_connect_data(drain_capsule)

    assert session.open?
  end

  def test_local_drain_sends_capsule_and_keeps_session_usable
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!

    session.drain!

    assert_equal drain_capsule, response_body(stream)
    refute stream.finished?
    assert session.open?
    assert session.accepts_new_streams?
  end

  def test_receive_connect_data_ignores_unknown_capsule
    session = build_session
    session.accept!
    closed = false
    capsule = Quicsilver::Protocol::Capsule.encode(0x2a, "ignored")

    session.on_close { closed = true }
    session.receive_connect_data(capsule)

    assert session.open?
    refute closed
  end

  def test_receive_connect_data_handles_multiple_capsules
    session = build_session
    session.accept!
    closed = false
    capsules = Quicsilver::Protocol::Capsule.encode(0x2a, "ignored") +
      close_capsule(7, "bye")

    session.on_close { closed = true }
    session.receive_connect_data(capsules)

    refute session.open?
    assert closed
  end

  def test_receive_connect_data_closes_session_when_capsule_is_too_large
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    closed = false
    # An oversized declared length is enough; no parser stubs or huge allocation.
    capsule = Quicsilver::Protocol.encode_varint(0x2a) +
      Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::Capsule::MAX_PAYLOAD_SIZE + 1)

    session.on_close { closed = true }
    session.receive_connect_data(capsule)

    assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, stream.error_code
    refute session.open?
    assert closed
  end

  def test_receive_connect_fin_closes_session_when_capsule_is_truncated
    stream = RecordingConnectStream.new
    session = build_session(stream: stream)
    session.accept!
    closed = false
    capsule = close_capsule(7, "bye")

    session.on_close { closed = true }
    session.receive_connect_fin(capsule.byteslice(0, 2))

    assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, stream.error_code
    refute session.open?
    assert closed
  end

  def test_receive_connect_fin_closes_session_after_complete_capsules
    session = build_session
    session.accept!
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

  def data_frame(payload) = Quicsilver::Protocol.build_frame(0, payload)

  def assert_datagram_sent(expected_connection_data, expected_payload)
    Quicsilver.stub(:datagram_send, ->(connection_data, payload) {
      assert_same expected_connection_data, connection_data
      assert_equal expected_payload, payload
      true
    }) do
      yield
    end
  end

  def build_session(headers: nil, connection: Object.new, stream: RecordingConnectStream.new)
    headers ||= {
      ":method" => "CONNECT", ":protocol" => "webtransport",
      ":scheme" => "https", ":authority" => "localhost:4433", ":path" => "/cable"
    }
    Session.new(connection: connection, stream: stream, headers: headers)
  end

  # Read the HTTP response body, independent of how many native sends wrote it.
  def response_body(stream)
    parser = Quicsilver::Protocol::ResponseParser.new(stream.bytes)
    parser.parse
    assert_equal 200, parser.status
    consumed = Quicsilver::Protocol::FrameReader.each(stream.bytes) { |_type, _payload| }
    assert_equal stream.bytes.bytesize, consumed, "Incomplete HTTP/3 response frame"
    parser.body.read
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

  # Collect transport output without prescribing call counts or chunk boundaries.
  # Real-peer tests in StreamLifetimeTest verify native FIN/STOP_SENDING behaviour.
  class RecordingConnectStream
    attr_reader :bytes, :error_code

    def initialize
      @bytes = "".b
      @finished = false
      @error_code = nil
    end

    def send(data, fin: false)
      @bytes << data
      @finished ||= fin
      true
    end

    def abort(code) = @error_code = code
    def finished? = @finished
    def stream_id = 0
    def stream_handle = 99_999
  end

  class RecordingConnection
    attr_reader :error_code

    def initialize = @error_code = nil
    def shutdown(code) = @error_code = code
  end
end
