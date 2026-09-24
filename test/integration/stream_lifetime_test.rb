# frozen_string_literal: true

require_relative "../webtransport_helper"

class StreamLifetimeTest < Minitest::Test
  include WebTransportHelpers

  REJECTION = 0x3994bd84
  MARKER = "stream-lifetime-test".b

  class RecordingClient < Quicsilver::Client
    attr_reader :events, :connection_error

    def initialize(...)
      @events = Queue.new
      super
    end

    def open_raw_stream(unidirectional: false)
      unidirectional ? open_unidirectional_stream : open_stream
    end

    def handle_stream_event(stream_id, event, data, early_data)
      if event == "CONNECTION_CLOSED" && @connection_data
        # The native context remains valid during this callback only.
        @connection_error = Quicsilver.connection_status(@connection_data[1])["error_code"]
      end
      @events << [stream_id, event, data]
      super
    end
  end

  class ServerStreamClient < RecordingClient
    private

    def create_configuration
      # Grant the server credit for WebTransport and HTTP/3 control streams.
      Quicsilver.create_configuration(true, true, true, 16, 16)
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
    attr_accessor :receive_callback

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
        @receive_callback&.call(stream_id, event, data) if %w[RECEIVE RECEIVE_FIN].include?(event)
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
    @wt_receive_options = {}
    app = ->(env) do
      if (session = env["quicsilver.context"]&.webtransport)
        origin = env["HTTP_ORIGIN"]
        next [403, {}, []] if origin && origin != "https://example.com"

        session.on_close { |info| @wt_closes << info }
        session.accept!(**@wt_receive_options)
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
    outgoing = @client.open_raw_stream(unidirectional: true)
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
    peer = @client.open_raw_stream
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "GET"], [":scheme", "https"], [":authority", "localhost"]
    ])
    peer.send(headers, fin: true) # Missing required :path.

    reset = await_event(@client, "STREAM_RESET", handle: peer.handle)
    assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, decode_event(reset).error_code
    assert_equal 200, @client.get("/").status
  end

  def test_fragmented_connect_headers_establish_without_fin
    @server.record_receives_for = :all
    headers = connect_headers
    [1, 2, headers.bytesize - 1].each do |split|
      peer = @client.open_raw_stream
      peer.send(headers.byteslice(0, split))
      id = await_connect_received(peer)
      assert @wt_sessions.empty?

      peer.send(headers.byteslice(split..))
      await_event(@server, "RECEIVE", id)
      session = @wt_sessions.pop(timeout: 3)
      refute_nil session, "CONNECT split at byte #{split} was not accepted"
      session.close
      assert_equal 200, read_connect_response_until_fin(id).status
      peer.send("", fin: true)
      await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    end
  end

  def test_non_https_webtransport_connect_is_rejected_before_rack
    ["webtransport-h3", "webtransport"].each do |protocol|
      peer = open_connect_stream(protocol: protocol, scheme: "http")

      assert_connect_rejected(peer, Quicsilver::Protocol::H3_MESSAGE_ERROR)
      assert @wt_sessions.empty?
      assert_equal 200, @client.get("/").status
    end
  end

  def test_rack_rejects_untrusted_origins_without_using_session_capacity
    ["https://untrusted.example", "https://example.com.attacker.test", "null"].each do |origin|
      peer = open_connect_stream(origin: origin)
      started = await_event(@client, "STREAM_START_COMPLETE", handle: peer.handle)

      assert_equal 403, read_connect_response_until_fin(started.first).status
      assert @wt_sessions.empty?, "Rejected Origin established a session"
      peer.send("", fin: true)
      await_event(@server, "STREAM_SHUTDOWN_COMPLETE", started.first)
    end

    peer = open_connect_stream(origin: "https://example.com")
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "Rejected Origins prevented a trusted session from opening"
    session.close
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
    peer.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_rack_can_accept_non_browser_clients_without_origin
    peer = open_connect_stream
    session = @wt_sessions.pop(timeout: 3)

    refute_nil session, "Origin is optional for non-browser clients"
    session.close
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
    peer.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
  end

  def test_invalid_bidi_session_id_closes_connection
    peer = @client.open_raw_stream
    peer.send(Quicsilver::Protocol.encode_varint(0x41) + Quicsilver::Protocol.encode_varint(1))

    await_event(@client, "CONNECTION_CLOSED")
    assert_equal Quicsilver::Protocol::H3_ID_ERROR, @client.connection_error
  end

  def test_invalid_uni_session_id_with_fin_closes_connection
    peer = @client.open_raw_stream(unidirectional: true)
    peer.send(Quicsilver::Protocol.encode_varint(0x54) + Quicsilver::Protocol.encode_varint(2), fin: true)

    await_event(@client, "CONNECTION_CLOSED")
    assert_equal Quicsilver::Protocol::H3_ID_ERROR, @client.connection_error
  end

  def test_fragmented_invalid_uni_session_id_closes_connection
    @server.record_receives_for = :all
    peer = @client.open_raw_stream(unidirectional: true)
    peer.send(Quicsilver::Protocol.encode_varint(0x54) + "\x40".b)
    await_event(@server, "RECEIVE")
    peer.send("\x03".b, fin: true)

    await_event(@client, "CONNECTION_CLOSED")
    assert_equal Quicsilver::Protocol::H3_ID_ERROR, @client.connection_error
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

  def test_modern_connect_requires_reliable_reset_but_legacy_still_works
    @client.disconnect
    @client = RecordingClient.new("localhost", @port, unsecure: true, reliable_reset_enabled: false)
    assert_equal 200, @client.get("/").status
    refute @server_connection.reliable_reset_enabled?

    peer = open_connect_stream
    assert_connect_rejected(peer, Quicsilver::Protocol::H3_MESSAGE_ERROR)
    assert @wt_sessions.empty?

    open_connect_stream(protocol: "webtransport")
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "Legacy clients do not negotiate reliable reset"
    session.close
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
  end

  def test_reliable_reset_delivers_prefix_before_reset
    assert_reliable_prefix_delivery(MARKER)
  end

  def test_reliable_reset_waits_for_flow_control_credit
    assert_reliable_prefix_delivery(MARKER + "x" * (1024 * 1024))
  end

  def test_immediate_server_bidi_reset_delivers_session_header
    assert_immediate_server_reset_delivers_header(:open_stream, 0x41)
  end

  def test_immediate_server_uni_reset_delivers_session_header
    assert_immediate_server_reset_delivers_header(:open_uni_stream, 0x54)
  end

  def test_session_close_during_bidi_open_rejects_open_cleanly
    assert_session_close_during_stream_open(:open_stream)
  end

  def test_session_close_during_uni_open_rejects_open_cleanly
    assert_session_close_during_stream_open(:open_uni_stream)
  end

  def test_server_reset_leaves_sibling_stream_and_datagrams_usable
    _, session = open_webtransport_session
    _, reset_stream = open_webtransport_child(session)
    sibling_peer, sibling = open_webtransport_child(session)

    reset_stream.reset(42)

    %w[STREAM_RESET STOP_SENDING].each do |signal|
      event = await_event(@client, signal, reset_stream.stream_id)
      assert_equal Quicsilver::Protocol::WebTransport.application_error_to_http(42), decode_event(event).error_code
    end
    assert_webtransport_usable(session, sibling_peer, sibling)
  end

  def test_peer_reset_reports_application_error_and_leaves_session_usable
    _, session = open_webtransport_session
    peer, reset_stream = open_webtransport_child(session)
    sibling_peer, sibling = open_webtransport_child(session)
    resets = Queue.new
    reset_stream.on_peer_reset { |code| resets << code }
    reset_stream.on_peer_stop_sending { |code| resets << code }

    peer.abort(Quicsilver::Protocol::WebTransport.application_error_to_http(42))

    # Aborting both directions produces RESET_STREAM and STOP_SENDING.
    assert_equal [42, 42], 2.times.map { resets.pop(timeout: 3) }
    refute reset_stream.open?
    assert_webtransport_usable(session, sibling_peer, sibling)
  end

  def test_peer_reset_keeps_the_stream_writable
    _, session = open_webtransport_session
    peer, stream = open_webtransport_child(session)
    resets = Queue.new
    stream.on_peer_reset { |code| resets << code }
    stream.on_peer_stop_sending { flunk "STOP_SENDING reported for a RESET_STREAM" }

    peer.reset(Quicsilver::Protocol::WebTransport.application_error_to_http(42))

    assert_equal 42, resets.pop(timeout: 3)
    assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    stream.write("response after reset")
    stream.close_write
    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN"], stream.stream_id)
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    assert_equal "response after reset", received
  end

  def test_peer_stop_sending_keeps_the_stream_readable
    _, session = open_webtransport_session
    peer, stream = open_webtransport_child(session)
    resets = Queue.new
    stream.on_peer_stop_sending { |code| resets << code }
    stream.on_peer_reset { flunk "RESET_STREAM reported for a STOP_SENDING" }

    peer.stop_sending(Quicsilver::Protocol::WebTransport.application_error_to_http(42))

    assert_equal 42, resets.pop(timeout: 3)
    assert_raises(IOError) { stream.write("too late") }
    peer.send("request after stop", fin: true)
    assert_equal "request after stop", stream.read
    assert_nil stream.read
  end

  # An unread child overflows its queue. The peer must see STOP_SENDING with
  # the configured code, and the rest of the connection must keep working.
  def test_receive_overflow_stops_the_unread_child_and_leaves_the_session_usable
    @wt_receive_options = {receive_buffer_bytes: 1024, receive_overflow_code: 42}
    _, session = open_webtransport_session
    starved_peer, starved = open_webtransport_child(session)
    sibling_peer, sibling = open_webtransport_child(session)
    overflow_code = Quicsilver::Protocol::WebTransport.application_error_to_http(42)

    # Never read from `starved`; push past its byte limit.
    starved_peer.send("x" * 4096)

    # The peer is told to stop sending, with our application code.
    event = await_event(@client, "STOP_SENDING", starved.stream_id)
    assert_equal overflow_code, decode_event(event).error_code

    # Our read side is closed; queued input was discarded, not delivered.
    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { starved.read }
    assert_equal 42, error.application_error_code

    # The write half survived, so the app can still answer on that stream.
    assert starved.open?
    starved.write("reader fell behind")
    starved.close_write
    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN"], starved.stream_id)
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    assert_equal "reader fell behind", received

    # Sibling stream, datagrams, and plain HTTP/3 keep working.
    assert_webtransport_usable(session, sibling_peer, sibling)
  end

  def test_session_close_aborts_bidi_and_receive_only_children
    _, session = open_webtransport_session
    _, bidi = open_webtransport_child(session)
    _, uni = open_webtransport_child(session, unidirectional: true)

    session.close

    [[bidi.stream_id, "STREAM_RESET"], [bidi.stream_id, "STOP_SENDING"], [uni.stream_id, "STOP_SENDING"]].each do |id, signal|
      event = await_event(@client, signal, id)
      assert_equal Quicsilver::Protocol::WebTransport::SESSION_GONE, decode_event(event).error_code
    end
    refute bidi.open?
    refute uni.open?
    assert_equal 200, read_connect_response_until_fin(session.stream_id).status
    assert_equal 200, @client.get("/").status
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

  def test_receive_credit_delivers_prefixes_and_defers_fin_until_replenished
    outgoing, incoming, id = open_stream
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 0, 1)
    outgoing.send("abcdef", fin: true)

    # Another connection must progress while this receiver has no credit.
    first_client = @client
    first_connection_handle = @server_connection.handle
    connect_client
    assert_equal 200, @client.get("/").status

    received = "".b
    [2, 2, 2].each_with_index do |credit, index|
      assert Quicsilver.grant_stream_receive_credit(incoming.handle, credit, 64)
      target = received.bytesize + credit
      while received.bytesize < target
        event = await_event(@server, ["RECEIVE", "RECEIVE_FIN"], id, connection: first_connection_handle)
        received << decode_event(event).data
        assert_operator received.bytesize, :<=, target
        assert_equal "RECEIVE", event[1] if index < 2
      end
      if index == 2 && event[1] != "RECEIVE_FIN"
        assert_empty decode_event(await_event(@server, "RECEIVE_FIN", id, connection: first_connection_handle)).data
      end
    end
    assert_equal "abcdef", received
  ensure
    first_client&.disconnect
  end

  def test_receive_credit_can_be_replenished_inside_the_receive_callback
    outgoing, incoming, id = open_stream
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 1, 1)
    @server.receive_callback = ->(_, event, _) do
      Quicsilver.grant_stream_receive_credit(incoming.handle, 1, 1) if event == "RECEIVE"
    end
    assert_delivers(outgoing, @server, id, "callback replenishment")
  end

  def test_first_receive_credit_grant_resumes_a_deferred_suffix
    outgoing, incoming, id = open_stream
    received = "".b
    @server.receive_callback = ->(_, event, data) do
      payload = Quicsilver::Transport::StreamEvent.new(data, event).data
      if received.empty?
        assert Quicsilver.defer_stream_receive(incoming.handle, payload.bytesize)
        assert Quicsilver.grant_stream_receive_credit(incoming.handle, 64, 64)
        received << "deferred:"
      else
        received << payload
      end
    end
    outgoing.send("resume after classification")
    until received == "deferred:resume after classification"
      await_event(@server, "RECEIVE", id)
    end
    assert_equal "deferred:resume after classification", received
  end

  def test_receive_chunk_credit_resumes_without_additional_byte_credit
    outgoing, incoming, id = open_stream
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 64, 1)
    outgoing.send("a")
    assert_equal "a", decode_event(await_event(@server, "RECEIVE", id)).data
    outgoing.send("b", fin: true)
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 0, 1)
    assert_equal "b", decode_event(await_event(@server, ["RECEIVE", "RECEIVE_FIN"], id)).data
  end

  def test_receive_credit_does_not_delay_an_empty_fin
    outgoing, incoming, id = open_stream
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 0, 1)
    outgoing.send("".b, fin: true)
    assert_empty decode_event(await_event(@server, "RECEIVE_FIN", id)).data
  end

  def test_receive_credit_rejects_invalid_grants_and_retired_tokens
    _, incoming, id = open_stream
    assert_raises(ArgumentError) { Quicsilver.grant_stream_receive_credit(incoming.handle, -1, 1) }
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, (1 << 64) - 1, 1)
    assert_raises(RangeError) { Quicsilver.grant_stream_receive_credit(incoming.handle, 1, 1) }
    assert incoming.abort(REJECTION)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    refute Quicsilver.grant_stream_receive_credit(incoming.handle, 1, 1)
  end

  def test_aborting_a_receiver_with_zero_credit_retires_its_token
    outgoing, incoming, id = open_stream
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 0, 1)
    outgoing.send("waiting for capacity")
    assert incoming.abort(REJECTION)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    refute Quicsilver.grant_stream_receive_credit(incoming.handle, 1, 1)
  end

  def test_receive_credit_aborts_when_ruby_delivery_raises
    outgoing, incoming, id = open_stream
    assert Quicsilver.grant_stream_receive_credit(incoming.handle, 4, 1)
    error = Class.new(StandardError) do
      def message = raise("exception formatting must not escape the native callback")
      def backtrace = raise("exception formatting must not escape the native callback")
    end.new
    @server.receive_callback = ->(*) { raise error }
    outgoing.send("data")
    await_event(@client, "STREAM_RESET", id)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    refute Quicsilver.grant_stream_receive_credit(incoming.handle, 1, 1)
  end

  def test_webtransport_bidi_backpressure_preserves_oversized_initial_payload_and_fin
    assert_webtransport_backpressure(unidirectional: false)
  end

  def test_webtransport_uni_backpressure_preserves_oversized_initial_payload_and_fin
    assert_webtransport_backpressure(unidirectional: true)
  end

  # STOP_SENDING closes our write side only. Input paused by backpressure is
  # still ours to drain, so the reader must finish the deferred suffix.
  def test_stop_sending_closes_only_the_write_side_with_paused_input
    session = accept_backpressured_session
    outgoing, incoming = open_webtransport_child(session)
    outgoing.send("abcdefghij")
    code = Quicsilver::Protocol::WebTransport.application_error_to_http(42)

    stops = Queue.new
    incoming.on_peer_stop_sending { |reported| stops << reported }
    incoming.on_peer_reset { flunk "RESET_STREAM reported for a STOP_SENDING" }

    assert outgoing.stop_sending(code)

    assert_equal 42, stops.pop(timeout: 3)
    assert_raises(IOError) { incoming.write("too late") }

    # The paused suffix still resumes and drains to FIN.
    outgoing.send("".b, fin: true)
    assert_equal "abcdefghij", drain_stream(incoming, 10)
    assert_nil incoming.read
  ensure
    session&.notify_close
  end

  def test_webtransport_initial_callback_failure_aborts_the_native_stream
    session = accept_backpressured_session
    failed = Queue.new
    session.on_stream do |stream|
      failed << stream.stream_id
      raise "Initial WebTransport delivery failed"
    end
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    prefix = Quicsilver::Protocol.encode_varint(session.class::WT_STREAM_BIDI) +
      Quicsilver::Protocol.encode_varint(session.stream_id)
    outgoing.send(prefix + "payload")
    id = failed.pop(timeout: 3)
    refute_nil id, "WebTransport callback was not invoked"

    await_event(@client, "STREAM_RESET", id)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id, connection: session.connection.handle)
  ensure
    session&.notify_close
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

  # Establish through the real CONNECT path so the session is registered and
  # accepted exactly as it is for an application.
  def accept_backpressured_session
    @wt_receive_options = {receive_backpressure: true, receive_buffer_bytes: 4, receive_buffer_chunks: 1}
    _, session = open_webtransport_session
    session
  end

  def assert_webtransport_backpressure(unidirectional:)
    session = accept_backpressured_session
    accepted = Queue.new
    session.on_stream { |stream| accepted << stream }
    session.on_uni_stream { |stream| accepted << stream }

    connection = @client.instance_variable_get(:@connection_data)
    handle = Quicsilver.open_stream(connection, unidirectional)
    outgoing = Quicsilver::Transport::Stream.new(handle)
    type = unidirectional ? session.class::WT_STREAM_UNI : session.class::WT_STREAM_BIDI
    prefix = Quicsilver::Protocol.encode_varint(type) + Quicsilver::Protocol.encode_varint(session.stream_id)
    payload = "abcdefghij".b
    outgoing.send(prefix + payload, fin: true)
    incoming = accepted.pop(timeout: 3)
    refute_nil incoming, "WebTransport child was not accepted"

    # A separate connection is unaffected by construction; the question is what
    # happens to a sibling sharing the paused connection's credit.
    other = RecordingClient.new("localhost", @port, unsecure: true, request_timeout: 3)
    assert_equal 200, other.get("/").status

    sibling_peer, sibling = open_webtransport_child(session)
    sibling_peer.send("sibling data", fin: true)
    assert_equal "sibling data", drain_stream(sibling, "sibling data".bytesize)

    # Prove the reply actually reaches the peer, not just that write returned.
    sibling.write("sibling reply")
    sibling.close_write
    reply = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], sibling.stream_id)
      refute_equal "STREAM_RESET", event[1]
      reply << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    assert_equal "sibling reply", reply
    assert_equal 200, @client.get("/").status

    reader = Thread.new do
      chunks = []
      while (chunk = incoming.read)
        chunks << chunk
      end
      chunks
    end
    reader.report_on_exception = false
    assert reader.join(3), "WebTransport reader did not resume to FIN"
    chunks = reader.value
    assert_equal payload, chunks.join
    assert chunks.all? { |chunk| chunk.bytesize <= 4 }, "Read exceeded the configured receive byte limit"
  ensure
    reader&.kill
    reader&.join(3)
    other&.disconnect
    session&.notify_close
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

  def assert_reliable_prefix_delivery(prefix)
    peer = @client.open_raw_stream
    @server.record_receives_for = :all
    peer.send(prefix)
    peer.reliable_offset = prefix.bytesize
    peer.reset(REJECTION)

    started = await_event(@client, "STREAM_START_COMPLETE", handle: peer.handle)
    received = "".b
    loop do
      event = await_event(@server, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], started.first)
      if event[1] == "STREAM_RESET"
        assert_equal REJECTION, decode_event(event).error_code
        break
      end
      refute_equal "RECEIVE_FIN", event[1], "Reliable reset must not appear as graceful FIN"
      received << decode_event(event).data
    end
    assert_equal prefix, received
    assert_equal 200, @client.get("/").status
  end

  def assert_immediate_server_reset_delivers_header(open_method, type)
    @client.disconnect
    @client = ServerStreamClient.new("localhost", @port, unsecure: true)
    assert_equal 200, @client.get("/").status
    _, session = open_webtransport_session

    stream = session.public_send(open_method)
    stream.reset(42)

    started = await_event(@server, "STREAM_START_COMPLETE", handle: stream.stream_handle)
    bytes = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], started.first)
      if event[1] == "STREAM_RESET"
        assert_equal 42, Quicsilver::Protocol::WebTransport.http_to_application_error(decode_event(event).error_code)
        break
      end
      refute_equal "RECEIVE_FIN", event[1], "Reset must not appear as graceful FIN"
      bytes << decode_event(event).data
    end
    assert_equal Quicsilver::Protocol.encode_varint(type) + Quicsilver::Protocol.encode_varint(session.stream_id), bytes
    assert session.open?
    assert_equal 200, @client.get("/").status
  end

  def assert_session_close_during_stream_open(open_method)
    _, session = open_webtransport_session
    paused = Queue.new
    resume = Queue.new
    # Pause before the header reaches native code; keep real QUIC sends/resets.
    @server_connection.define_singleton_method(:open_stream) do |**options|
      super(**options).tap do |stream|
        stream.define_singleton_method(:send) do |*args, **kwargs|
          paused << self
          resume.pop
          super(*args, **kwargs)
        end
      end
    end
    opening = Thread.new do
      session.public_send(open_method)
    rescue StandardError => error
      error
    end
    stream = paused.pop(timeout: 3)
    refute_nil stream, "Stream opening did not reach the header send"
    session.close
    resume << true
    assert opening.join(3), "Stream opening did not finish after session closure"
    assert_kind_of RuntimeError, opening.value
    assert_equal "Session not open", opening.value.message
    assert session.closed?
    assert_equal 200, @client.get("/").status
  ensure
    resume << true if resume
    opening&.join(3)
  end

  def open_webtransport_child(session, unidirectional: false)
    accepted = Queue.new
    if unidirectional
      session.on_uni_stream { |stream| accepted << stream }
    else
      session.on_stream { |stream| accepted << stream }
    end
    peer = @client.open_raw_stream(unidirectional: unidirectional)
    type = unidirectional ? 0x54 : 0x41
    peer.send(Quicsilver::Protocol.encode_varint(type) + Quicsilver::Protocol.encode_varint(session.stream_id))
    stream = accepted.pop(timeout: 3)
    refute_nil stream, "WebTransport child stream was not accepted"
    [peer, stream]
  end

  def assert_webtransport_usable(session, peer, stream)
    stream.write("still here")
    stream.close_write
    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], stream.stream_id)
      refute_equal "STREAM_RESET", event[1]
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    assert_equal "still here", received
    peer.send("", fin: true)

    session.on_datagram { |data| session.send_datagram("echo: #{data}") }
    @client.datagram_send(Quicsilver::Protocol::Datagram.encode(session.stream_id, "ping"))
    datagram = await_event(@client, "DATAGRAM_RECEIVED")
    assert_equal [session.stream_id, "echo: ping"], Quicsilver::Protocol::Datagram.decode(datagram[2])
    assert session.open?
    assert_equal 200, @client.get("/").status
  end

  # Initial data shares the same send as HEADERS to exercise CONNECT handoff.
  def open_connect_stream(initial_data: "".b, protocol: "webtransport-h3", scheme: "https", origin: nil, fin: false)
    peer = @client.open_raw_stream
    peer.send(connect_headers(protocol: protocol, scheme: scheme, origin: origin) + initial_data, fin: fin)
    peer
  end

  def connect_headers(protocol: "webtransport-h3", scheme: "https", origin: nil)
    headers = [
      [":method", "CONNECT"], [":protocol", protocol],
      [":scheme", scheme], [":authority", "localhost"], [":path", "/wt"]
    ]
    headers << ["origin", origin] if origin
    Quicsilver::Protocol.build_headers_frame(headers)
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
    outgoing = @client.open_raw_stream(unidirectional: unidirectional)
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
