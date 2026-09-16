# frozen_string_literal: true

require "test_helper"

class StreamLifetimeTest < Minitest::Test
  REJECTION = 0x3994bd84
  MARKER = "stream-lifetime-test".b

  class RecordingClient < Quicsilver::Client
    attr_reader :events

    def initialize(...)
      @events = Queue.new
      super
    end

    def handle_stream_event(stream_id, event, data, early_data)
      @events << [stream_id, event, data]
      super
    end
  end

  class SettingsClient < RecordingClient
    def send_settings(settings)
      @control_stream.send("\x00".b + Quicsilver::Protocol.build_settings_frame(settings))
    end

    private

    def send_control_stream
      @control_stream = open_unidirectional_stream
    end
  end

  class RecordingServer < Quicsilver::Server
    attr_reader :events
    attr_writer :record_receives_for

    def initialize(...)
      @events = Queue.new
      @test_streams = {}
      @record_receives_for = nil
      super
    end

    def handle_stream_event(connection, stream_id, event, data, early_data)
      record_receive = %w[RECEIVE RECEIVE_FIN].include?(event) && (@record_receives_for == :all || stream_id == @record_receives_for)
      key = [connection.first, stream_id]
      if %w[RECEIVE RECEIVE_FIN].include?(event) && Quicsilver::Transport::StreamEvent.new(data, event).data.start_with?(MARKER)
        @test_streams[key] = true
      end

      if @test_streams[key]
        @events << [stream_id, event, data, connection.first]
        return
      end

      super
      if record_receive || %w[CONNECTION_CLOSED STREAM_START_COMPLETE STREAM_SHUTDOWN_COMPLETE].include?(event)
        @events << [stream_id, event, data, connection.first]
      end
    end
  end

  def setup
    @inbox = Hash.new { |hash, key| hash[key] = [] }
    @port = find_available_port
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    @wt_sessions = Queue.new
    @wt_closes = Queue.new
    app = ->(env) do
      if (session = env["quicsilver.context"]&.webtransport)
        session.on_close { |info| @wt_closes << info }
        session.accept!
        @wt_sessions << session
        [200, {}, []]
      else
        [200, {}, ["OK"]]
      end
    end
    @server = RecordingServer.new(@port, server_configuration: config, app: app)
    Quicsilver::Server.instance = @server
    @server.on_connection { |connection| @server_connection = connection }
    @server_thread = Thread.new { @server.start }
    wait_for_server(@server)
    connect_client
  end

  def teardown
    @client&.disconnect
    @server&.stop
    @server_thread&.join(3)
  end

  def test_aborting_incoming_uni_stream_requests_peer_to_stop
    _, incoming, id = open_stream(unidirectional: true)

    refute incoming.reset(REJECTION)
    assert incoming.abort(REJECTION)

    event = await_event(@client, "STOP_SENDING", id)
    assert_equal REJECTION, decode_event(event).error_code
  end

  def test_aborting_outgoing_uni_stream_resets_peer_receive_side
    outgoing, _, id = open_stream(unidirectional: true)

    refute outgoing.stop_sending(REJECTION)
    assert outgoing.abort(REJECTION)

    event = await_event(@server, "STREAM_RESET", id)
    assert_equal REJECTION, decode_event(event).error_code
  end

  def test_aborting_bidi_stream_closes_both_directions
    _, incoming, id = open_stream

    assert incoming.abort(REJECTION)

    %w[STREAM_RESET STOP_SENDING].each do |signal|
      event = await_event(@client, signal, id)
      assert_equal REJECTION, decode_event(event).error_code
    end
  end

  def test_shutdown_invalidates_all_wrappers
    _, incoming, id = open_stream
    alias_stream = Quicsilver::Transport::Stream.new(incoming.handle)
    assert incoming.abort(REJECTION)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)

    assert_retired(incoming)
    assert_retired(alias_stream)
  end

  def test_clean_fin_retires_a_unidirectional_stream
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, true))
    outgoing.send(MARKER, fin: true)
    event = await_event(@server, "RECEIVE_FIN")
    id = event.first
    incoming = Quicsilver::Transport::Stream.new(decode_event(event).handle)

    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    await_event(@client, "STREAM_SHUTDOWN_COMPLETE", id)
    assert_retired(incoming)
    assert_retired(outgoing)
  end

  def test_disconnect_invalidates_both_endpoints_before_late_operations
    outgoing, incoming, = open_stream
    @client.disconnect
    @server_connection.shutdown
    await_event(@server, "CONNECTION_CLOSED", connection: @server_connection.handle)

    assert_retired(outgoing)
    assert_retired(incoming)

    connect_client
    fresh, fresh_incoming, id = open_stream
    assert_retired(outgoing)
    assert_retired(incoming)
    assert_delivers(fresh, @server, id, "after reconnect")
    assert_delivers(fresh_incoming, @client, id, "reply after reconnect")
  end

  def test_retired_stream_operations_leave_new_stream_usable
    retired = []
    8.times do
      _, incoming, id = open_stream
      assert incoming.abort(REJECTION)
      await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
      retired << incoming
    end

    outgoing, incoming, id = open_stream
    retired.each { |stream| assert_retired(stream) }

    assert_delivers(outgoing, @server, id, "still receiving")
    assert_delivers(incoming, @client, id, "still sending")
  end

  def test_closing_one_connection_leaves_another_connections_stream_usable
    first_client = @client
    first_connection = @server_connection
    first_outgoing, first_incoming, first_id = open_stream
    closed = Queue.new
    @server.on_connection_closed { |connection| closed << connection.handle }

    connect_client
    outgoing, incoming, id = open_stream
    assert_equal first_id, id

    first_connection.shutdown
    assert_equal first_connection.handle, closed.pop(timeout: 3)
    assert_retired(first_incoming)
    assert_delivers(outgoing, @server, id, "still receiving")
    assert_delivers(incoming, @client, id, "still sending")

    @server_connection.shutdown
    event = await_event(@server, "CONNECTION_CLOSED", connection: @server_connection.handle)
    assert_equal @server_connection.handle, event[3]
    assert_retired(incoming)
    first_client.disconnect
    assert_retired(first_outgoing)
  ensure
    first_client&.disconnect
  end

  def test_send_fails_safely_when_argument_conversion_closes_stream
    _, incoming, id = open_stream
    data = Object.new
    data.define_singleton_method(:to_str) do
      incoming.abort(REJECTION)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      until incoming.stream_id.nil?
        raise "Stream did not shut down" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        Thread.pass
      end
      "late"
    end

    assert_raises(IOError) { incoming.send(data) }
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    assert_retired(incoming)
  end

  def test_priority_setter_accepts_native_range_and_rejects_overflow
    _, incoming, = open_stream

    assert Quicsilver.set_stream_priority(incoming.handle, 0)
    assert Quicsilver.set_stream_priority(incoming.handle, 65_535)
    assert_raises(ArgumentError) { Quicsilver.set_stream_priority(incoming.handle, 65_536) }
  end

  def test_connect_waits_for_settings_and_preserves_close_data_and_fin
    connect_without_settings
    peer = open_connect_stream
    id = await_connect_received(peer)
    assert @wt_sessions.empty?, "CONNECT must wait for peer SETTINGS"

    peer.send(data_frame(close_capsule(code: 7, reason: "waiting")), fin: true)
    await_event(@server, "RECEIVE_FIN", id)
    assert @wt_sessions.empty?
    @client.send_settings(webtransport_settings)

    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "SETTINGS did not release the pending CONNECT"
    info = @wt_closes.pop(timeout: 3)
    refute_nil info
    assert_equal 7, info.code
    assert_equal "waiting", info.reason
    assert_equal 200, read_connect_response_until_fin(id).status
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
  end

  def test_connect_sent_with_fin_waits_for_settings
    connect_without_settings
    open_connect_stream(fin: true)
    received = await_event(@server, "RECEIVE_FIN")
    assert @wt_sessions.empty?, "FIN must not bypass the SETTINGS gate"

    @client.send_settings(webtransport_settings)

    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "SETTINGS did not release CONNECT sent with FIN"
    assert_equal received.first, session.stream_id
    assert_equal 0, @wt_closes.pop(timeout: 3)&.code
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
  end

  def test_connect_sent_with_fin_is_rejected_without_required_settings
    connect_without_settings
    @client.send_settings({})
    peer = open_connect_stream(fin: true)

    assert_connect_rejected(peer, Quicsilver::Protocol::H3_MESSAGE_ERROR)
    assert @wt_sessions.empty?
    assert_equal 200, @client.get("/").status
  end

  def test_completed_http_request_still_resets_on_invalid_headers
    connection = @client.instance_variable_get(:@connection_data)
    peer = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "GET"], [":scheme", "https"], [":authority", "localhost"]
    ])
    peer.send(headers, fin: true) # Missing required :path.

    reset = await_event(@client, "STREAM_RESET", handle: peer.handle)
    assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, decode_event(reset).error_code
    assert_equal 200, @client.get("/").status
  end

  def test_missing_webtransport_settings_reject_connect_before_rack
    [{}, {0x33 => 1}, {0x2c7cf000 => 1}, {0x33 => 1, 0x2c7cf000 => 0}].each do |settings|
      connect_without_settings
      @client.send_settings(settings)
      peer = open_connect_stream

      assert_connect_rejected(peer, Quicsilver::Protocol::H3_MESSAGE_ERROR)
      assert @wt_sessions.empty?
      assert_equal 200, @client.get("/").status
    end
  end

  def test_client_can_disable_datagrams_and_still_use_http
    @client.disconnect
    @client = RecordingClient.new("localhost", @port, unsecure: true, datagram_receive_enabled: false)

    assert_equal 200, @client.get("/").status
    refute @server_connection.datagram_send_enabled?
    refute @server_connection.webtransport_settings_valid?("webtransport-h3")
  end

  def test_http_datagram_setting_cannot_replace_quic_datagram_negotiation
    ["webtransport-h3", "webtransport"].each do |protocol|
      connect_without_settings(datagram_receive_enabled: false)
      @client.send_settings(webtransport_settings)
      peer = open_connect_stream(protocol: protocol)

      assert_connect_rejected(peer, Quicsilver::Protocol::H3_MESSAGE_ERROR)
      assert @wt_sessions.empty?, "HTTP SETTINGS alone must not admit WebTransport"
      assert_equal 200, @client.get("/").status
    end
  end

  def test_legacy_connect_accepts_datagram_settings_without_draft16_flag
    connect_without_settings
    @client.send_settings(0x33 => 1)
    peer = open_connect_stream(protocol: "webtransport")

    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "Legacy CONNECT with datagram support was rejected"
    session.close
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
    peer.send("", fin: true)
  end

  def test_invalid_settings_reject_an_already_waiting_connect
    connect_without_settings
    peer = open_connect_stream
    await_connect_received(peer)
    assert @wt_sessions.empty?

    @client.send_settings({})

    assert_connect_rejected(peer, Quicsilver::Protocol::H3_MESSAGE_ERROR)
    assert @wt_sessions.empty?
  end

  def test_waiting_connect_buffer_is_bounded
    connect_without_settings
    peer = open_connect_stream
    await_connect_received(peer)

    peer.send(data_frame("x" * 65_537))

    assert_connect_rejected(peer, Quicsilver::Protocol::H3_EXCESSIVE_LOAD)
    @client.send_settings(webtransport_settings)
    assert_equal 200, @client.get("/").status
    assert @wt_sessions.empty?, "An overflowed CONNECT must never reach Rack"
    open_webtransport_session
  end

  def test_only_one_connect_can_wait_for_settings
    connect_without_settings
    first = open_connect_stream
    id = await_connect_received(first)
    second = open_connect_stream

    assert_connect_rejected(second, Quicsilver::Protocol::H3_REQUEST_REJECTED)
    @client.send_settings(webtransport_settings)

    session = @wt_sessions.pop(timeout: 3)
    refute_nil session
    assert_equal id, session.stream_id
    assert @wt_sessions.empty?
  end

  def test_reset_discards_connect_waiting_for_settings
    connect_without_settings
    peer = open_connect_stream
    id = await_connect_received(peer)
    peer.abort(Quicsilver::Protocol::H3_REQUEST_CANCELLED)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)

    @client.send_settings(webtransport_settings)
    _, replacement = open_webtransport_session

    refute_equal id, replacement.stream_id
    assert @wt_sessions.empty?, "Reset CONNECT must not be replayed after SETTINGS"
  end

  def test_stop_sending_discards_connect_waiting_for_settings
    connect_without_settings
    peer = open_connect_stream
    id = await_connect_received(peer)
    peer.stop_sending(Quicsilver::Protocol::H3_REQUEST_CANCELLED)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)

    @client.send_settings(webtransport_settings)
    _, replacement = open_webtransport_session

    refute_equal id, replacement.stream_id
    assert @wt_sessions.empty?, "Cancelled CONNECT must not be replayed after SETTINGS"
  end

  def test_connection_close_discards_connect_waiting_for_settings
    connect_without_settings
    peer = open_connect_stream
    await_connect_received(peer)
    previous_connection = @server_connection.handle
    @server_connection.shutdown
    await_event(@server, "CONNECTION_CLOSED", connection: previous_connection)
    @client.disconnect

    connect_client
    open_webtransport_session

    assert @wt_sessions.empty?, "Disconnected CONNECT must not reach the Rack app"
  end

  def test_second_session_is_rejected_without_affecting_the_first
    peer, session = open_webtransport_session

    rejected = open_connect_stream
    reset = await_event(@client, "STREAM_RESET")
    assert_equal rejected.handle, decode_event(reset).handle
    assert_equal Quicsilver::Protocol::H3_REQUEST_REJECTED, decode_event(reset).error_code
    stopped = await_event(@client, "STOP_SENDING", reset.first)
    assert_equal Quicsilver::Protocol::H3_REQUEST_REJECTED, decode_event(stopped).error_code
    await_event(@client, "STREAM_SHUTDOWN_COMPLETE", reset.first)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", reset.first)
    assert @wt_sessions.empty?, "Excess CONNECT must not reach the Rack app"
    assert session.open?
    assert_equal 200, @client.get("/").status

    session.close(code: 7, reason: "still usable")
    response = read_connect_response_until_fin(session.stream_id)
    assert_equal close_capsule(code: 7, reason: "still usable"), response.body.read
    peer.send("", fin: true)
  end

  def test_closing_a_session_allows_another_on_the_same_connection
    peer, session = open_webtransport_session
    session.close
    read_connect_response_until_fin(session.stream_id)
    peer.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)

    replacement_peer, replacement = open_webtransport_session

    assert replacement.open?
    refute_equal session.stream_id, replacement.stream_id
    replacement.close
    assert_equal 200, read_connect_response_until_fin(replacement.stream_id).status
    replacement_peer.send("", fin: true)
  end

  def test_close_alongside_connect_headers_reaches_the_session
    peer, session = open_webtransport_session(
      initial_data: data_frame(close_capsule(code: 9, reason: "coalesced"))
    )

    info = @wt_closes.pop(timeout: 3)
    refute_nil info, "Coalesced CLOSE was lost during CONNECT dispatch"
    assert_equal 9, info.code
    assert_equal "coalesced", info.reason
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status

    peer.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_partial_following_frame_does_not_block_connect_acceptance
    # Send the extension frame type with CONNECT, then its length after acceptance.
    peer, session = open_webtransport_session(
      initial_data: Quicsilver::Protocol.encode_varint(0x4041)
    )
    peer.send(Quicsilver::Protocol.encode_varint(0), fin: true)

    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_data_after_close_stops_peer_and_retires_connect_stream
    peer, session = open_webtransport_session(initial_data: data_frame(close_capsule))
    read_connect_response_until_fin(session.stream_id)

    # Keep the request direction open and exercise the connection before late data.
    assert_equal 200, @client.get("/").status
    peer.send(data_frame("forbidden"))

    stopped = await_event(@client, "STOP_SENDING", session.stream_id)
    assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, decode_event(stopped).error_code
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    await_event(@client, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_retired(peer)
    assert_equal 200, @client.get("/").status
  end

  def test_local_close_delivers_reason_and_fin_to_peer
    peer, session = open_webtransport_session

    session.close(code: 42, reason: "maintenance")

    response = read_connect_response_until_fin(session.stream_id)
    assert_equal 200, response.status
    assert_equal close_capsule(code: 42, reason: "maintenance"), response.body.read
    peer.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_fragmented_peer_close_preserves_reason_and_finishes_response
    peer, session = open_webtransport_session
    @server.record_receives_for = session.stream_id
    capsule = close_capsule(code: 7, reason: "bye")
    wire = data_frame(capsule.byteslice(0, 4)) + data_frame(capsule.byteslice(4..))

    # Wait for production routing after each byte to prevent receive coalescing.
    wire.each_byte do |byte|
      peer.send(byte.chr.b)
      await_event(@server, "RECEIVE", session.stream_id)
    end
    peer.send("", fin: true)

    response = read_connect_response_until_fin(session.stream_id)
    assert_equal 200, response.status
    assert_empty response.body.read
    info = @wt_closes.pop(timeout: 3)
    refute_nil info, "Close notification did not reach the application"
    assert_equal 7, info.code
    assert_equal "bye", info.reason
    assert info.remote?
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert @wt_closes.empty?, "Session close notified the application more than once"
    assert_equal 200, @client.get("/").status
  end

  def test_session_shutdown_aborts_bidi_and_receive_only_children
    _, bidi, bidi_id = open_stream
    _, uni, uni_id = open_stream(unidirectional: true)
    session = Quicsilver::Server::WebTransportSession.new(
      connection: @server_connection, stream: bidi, headers: {}
    )
    session.add_stream(bidi.handle, bidi_id)
    session.add_uni_stream(uni.handle, uni_id)

    session.notify_close
    session.notify_close

    [[bidi_id, "STREAM_RESET"], [bidi_id, "STOP_SENDING"], [uni_id, "STOP_SENDING"]].each do |id, signal|
      event = await_event(@client, signal, id)
      assert_equal Quicsilver::Protocol::WebTransport::SESSION_GONE, decode_event(event).error_code
    end
    assert_nil session.stream(bidi_id)
    assert_nil session.stream(uni_id)
  end

  def test_streams_opened_in_a_native_callback_get_ids_and_close_while_peer_blocked
    _, connect_stream, = open_stream
    session = Quicsilver::Server::WebTransportSession.new(
      connection: @server_connection, stream: connect_stream, headers: {}
    )
    manager = @server.instance_variable_get(:@webtransport).for(@server_connection.handle)
    manager.register(session)
    session.accept!
    opened = Queue.new
    @server.on_datagram do |_connection, _data|
      opened << [session.open_stream, session.open_uni_stream]
    end

    @client.datagram_send("open server streams")
    streams = opened.pop(timeout: 3)
    refute_nil streams, "Server did not open the streams"
    waiting = streams.map(&:stream_handle)
    until waiting.empty?
      event = await_event(@server, "STREAM_START_COMPLETE", connection: @server_connection.handle)
      started = decode_event(event)
      next unless waiting.delete(started.handle)

      assert_equal 0, event[2].getbyte(8), "Peer unexpectedly accepted the stream"
    end

    bidi, uni = streams
    refute_nil bidi.stream_id
    refute_nil uni.stream_id
    refute_equal bidi.stream_id, uni.stream_id
    session.notify_close

    streams.each do |stream|
      refute stream.open?
      assert_nil session.stream(stream.stream_id)
    end

    @server_connection.shutdown
    await_event(@server, "CONNECTION_CLOSED", connection: @server_connection.handle)

    streams.each do |stream|
      assert_retired(Quicsilver::Transport::Stream.new(stream.stream_handle))
    end
  end

  def test_unknown_session_rejection_reaches_the_peer
    _, incoming, id = open_stream
    manager = Quicsilver::Server::WebTransportManager.new
    prefix = Quicsilver::Protocol.encode_varint(0x41) + Quicsilver::Protocol.encode_varint(0)

    assert_nil manager.accept_bidi_stream(id, incoming.handle, prefix + "hello")

    %w[STREAM_RESET STOP_SENDING].each do |signal|
      event = await_event(@client, signal, id)
      assert_equal REJECTION, decode_event(event).error_code
    end
    assert_equal 200, @client.get("/").status
  end

  def test_failed_async_start_retires_the_stream
    opened = Queue.new
    @server.on_datagram do |_connection, _data|
      @server_connection.shutdown
      opened << @server_connection.open_stream
    end

    @client.datagram_send("open while shutting down")
    stream = opened.pop(timeout: 3)
    refute_nil stream, "Stream was not opened"
    failed_id = (1 << 64) - 1
    started = await_event(@server, "STREAM_START_COMPLETE", failed_id, connection: @server_connection.handle)
    assert_equal stream.handle, decode_event(started).handle
    shutdown = await_event(@server, "STREAM_SHUTDOWN_COMPLETE", failed_id, connection: @server_connection.handle)
    assert_equal stream.handle, decode_event(shutdown).handle
    assert_retired(stream)
  end

  private

  def connect_without_settings(**options)
    @client&.disconnect
    @client = SettingsClient.new("localhost", @port, unsecure: true, request_timeout: 3, **options)
    assert_equal 200, @client.get("/").status
    @server.record_receives_for = :all
  end

  def webtransport_settings
    {0x33 => 1, 0x2c7cf000 => 1}
  end

  def await_connect_received(peer)
    started = await_event(@client, "STREAM_START_COMPLETE", handle: peer.handle)
    await_event(@server, "RECEIVE", started.first)
    started.first
  end

  def assert_connect_rejected(peer, code)
    reset = await_event(@client, "STREAM_RESET", handle: peer.handle)
    assert_equal code, decode_event(reset).error_code
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", reset.first)
  end

  def connect_client
    @client = RecordingClient.new("localhost", @port, unsecure: true, request_timeout: 3)
    assert_equal 200, @client.get("/").status
  end

  def open_webtransport_session(initial_data: "".b)
    peer = open_connect_stream(initial_data: initial_data)
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "CONNECT did not reach Rack acceptance"
    [peer, session]
  end

  # Initial data shares the same send as HEADERS to exercise CONNECT handoff.
  def open_connect_stream(initial_data: "".b, protocol: "webtransport-h3", fin: false)
    connection = @client.instance_variable_get(:@connection_data)
    peer = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "CONNECT"], [":protocol", protocol],
      [":scheme", "https"], [":authority", "localhost"], [":path", "/wt"]
    ])
    peer.send(headers + initial_data, fin: fin)
    peer
  end

  def read_connect_response_until_fin(stream_id)
    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], stream_id)
      refute_equal "STREAM_RESET", event[1], "CONNECT reset can discard the close reason"
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    parser = Quicsilver::Protocol::ResponseParser.new(received)
    parser.parse
    consumed = Quicsilver::Protocol::FrameReader.each(received) { |_type, _payload| }
    assert_equal received.bytesize, consumed, "Incomplete HTTP/3 response frame"
    parser
  end

  def data_frame(payload)
    Quicsilver::Protocol.build_frame(Quicsilver::Protocol::FRAME_DATA, payload)
  end

  def close_capsule(code: 0, reason: "")
    Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Protocol::WebTransport::CLOSE_SESSION_CAPSULE,
      [code].pack("N") + reason.b
    )
  end

  def open_stream(unidirectional: false)
    connection = @client.instance_variable_get(:@connection_data)
    handle = Quicsilver.open_stream(connection, unidirectional)
    outgoing = Quicsilver::Transport::Stream.new(handle)
    outgoing.send(MARKER)
    event = await_event(@server, "RECEIVE")
    id = event.first
    incoming = Quicsilver::Transport::Stream.new(decode_event(event).handle)
    [outgoing, incoming, id]
  end

  def decode_event(event)
    Quicsilver::Transport::StreamEvent.new(event[2], event[1])
  end

  def assert_delivers(stream, peer, id, payload)
    stream.send(payload, fin: true)
    received = "".b
    loop do
      event = await_event(peer, ["RECEIVE", "RECEIVE_FIN"], id)
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    assert_equal payload, received
  end

  def assert_retired(stream)
    assert_nil stream.stream_id
    refute stream.reset(REJECTION)
    refute stream.stop_sending(REJECTION)
    refute stream.abort(REJECTION)
    refute Quicsilver.set_stream_priority(stream.handle, 1)
    assert_raises(IOError) { stream.send("late") }
  end

  def await_event(endpoint, type, id = nil, connection: nil, handle: nil)
    connection ||= @server_connection.handle if endpoint.equal?(@server)
    inbox = @inbox[endpoint]
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    types = Array(type)
    loop do
      index = inbox.index do |event|
        types.include?(event[1]) && (id.nil? || event[0] == id) &&
          (connection.nil? || event[3] == connection) &&
          (handle.nil? || decode_event(event).handle == handle)
      end
      return inbox.delete_at(index) if index

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_operator remaining, :>, 0, "Timed out waiting for #{type} on #{id}"
      event = endpoint.events.pop(timeout: remaining)
      refute_nil event, "Timed out waiting for #{type} on #{id}"
      inbox << event
    end
  end
end
