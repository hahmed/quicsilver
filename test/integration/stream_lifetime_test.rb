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
      record_receive = event == "RECEIVE" && stream_id == @record_receives_for
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

  def test_real_connect_dispatch_preserves_coalesced_close_capsule
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "CONNECT"], [":protocol", "webtransport-h3"],
      [":scheme", "https"], [":authority", "localhost"], [":path", "/wt"]
    ])
    capsule = Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Protocol::WebTransport::CLOSE_SESSION_CAPSULE,
      [9].pack("N") + "coalesced"
    )
    outgoing.send(headers + Quicsilver::Protocol.build_frame(0, capsule))
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "CONNECT did not reach the Rack app"
    info = @wt_closes.pop(timeout: 3)
    refute_nil info, "Coalesced CLOSE was lost during CONNECT dispatch"
    assert_equal 9, info.code
    assert_equal "coalesced", info.reason
    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], session.stream_id)
      refute_equal "STREAM_RESET", event[1]
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    parser = Quicsilver::Protocol::ResponseParser.new(received)
    parser.parse
    assert_equal 200, parser.status
    outgoing.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_connect_dispatch_preserves_partial_following_extension_frame
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "CONNECT"], [":protocol", "webtransport-h3"],
      [":scheme", "https"], [":authority", "localhost"], [":path", "/wt"]
    ])

    # The extension frame type is complete, but its length arrives later.
    # CONNECT acceptance must not wait for the following frame to complete.
    outgoing.send(headers + Quicsilver::Protocol.encode_varint(0x4041))
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "Complete CONNECT headers were lost with a partial following frame"
    outgoing.send(Quicsilver::Protocol.encode_varint(0), fin: true)

    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], session.stream_id)
      refute_equal "STREAM_RESET", event[1]
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    parser = Quicsilver::Protocol::ResponseParser.new(received)
    parser.parse
    assert_equal 200, parser.status
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_equal 200, @client.get("/").status
  end

  def test_trailing_connect_data_after_response_fin_stops_peer_and_retires_stream
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    headers = Quicsilver::Protocol.build_headers_frame([
      [":method", "CONNECT"], [":protocol", "webtransport-h3"],
      [":scheme", "https"], [":authority", "localhost"], [":path", "/wt"]
    ])
    capsule = Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Protocol::WebTransport::CLOSE_SESSION_CAPSULE, [0].pack("N")
    )
    outgoing.send(headers + Quicsilver::Protocol.build_frame(0, capsule))
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session
    await_event(@client, "RECEIVE_FIN", session.stream_id)

    # Keep the request direction open after receiving the server's FIN.
    # A separate request exercises the connection before sending late data.
    assert_equal 200, @client.get("/").status
    outgoing.send(Quicsilver::Protocol.build_frame(0, "forbidden"))
    stopped = await_event(@client, "STOP_SENDING", session.stream_id)
    assert_equal Quicsilver::Protocol::H3_MESSAGE_ERROR, decode_event(stopped).error_code
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    await_event(@client, "STREAM_SHUTDOWN_COMPLETE", session.stream_id)
    assert_retired(outgoing)
    assert_equal 200, @client.get("/").status
  end

  def test_session_close_delivers_capsule_and_fin_to_native_peer
    outgoing, incoming, id = open_stream
    session = Quicsilver::Server::WebTransportSession.new(
      connection: @server_connection, stream: incoming, headers: {}
    )
    session.accept!
    session.close(code: 42, reason: "maintenance")

    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], id)
      refute_equal "STREAM_RESET", event[1], "CONNECT reset can discard the close reason"
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    expected = Quicsilver::Protocol.build_headers_frame([[":status", "200"]]) +
      Quicsilver::Protocol.build_frame(0, Quicsilver::Protocol::Capsule.encode(
        Quicsilver::Protocol::WebTransport::CLOSE_SESSION_CAPSULE,
        [42].pack("N") + "maintenance"
      ))
    assert_equal expected, received
    outgoing.send("", fin: true)
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id)
    assert_equal 200, @client.get("/").status
  end

  def test_fragmented_peer_close_capsule_finishes_connect_response
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    outgoing.send(Quicsilver::Protocol.build_headers_frame([
      [":method", "CONNECT"], [":protocol", "webtransport-h3"],
      [":scheme", "https"], [":authority", "localhost"], [":path", "/wt"]
    ]))
    session = @wt_sessions.pop(timeout: 3)
    refute_nil session, "CONNECT did not reach the Rack app"
    @server.record_receives_for = session.stream_id
    capsule = Quicsilver::Protocol::Capsule.encode(
      Quicsilver::Protocol::WebTransport::CLOSE_SESSION_CAPSULE,
      [7].pack("N") + "bye"
    )
    wire = Quicsilver::Protocol.build_frame(0, capsule.byteslice(0, 4)) +
      Quicsilver::Protocol.build_frame(0, capsule.byteslice(4..))

    # Wait for actual server receipt before sending each next byte so MsQuic
    # cannot coalesce the split frame headers and capsule into one indication.
    # The server observer records events only after normal production routing.
    wire.each_byte do |byte|
      outgoing.send(byte.chr.b)
      await_event(@server, "RECEIVE", session.stream_id)
    end
    outgoing.send("", fin: true)

    received = "".b
    loop do
      event = await_event(@client, ["RECEIVE", "RECEIVE_FIN", "STREAM_RESET"], session.stream_id)
      refute_equal "STREAM_RESET", event[1]
      received << decode_event(event).data
      break if event[1] == "RECEIVE_FIN"
    end
    parser = Quicsilver::Protocol::ResponseParser.new(received)
    parser.parse
    assert_equal 200, parser.status
    assert_empty parser.body.read
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

  def connect_client
    @client = RecordingClient.new("localhost", @port, unsecure: true, request_timeout: 3)
    assert_equal 200, @client.get("/").status
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

  def await_event(endpoint, type, id = nil, connection: nil)
    connection ||= @server_connection.handle if endpoint.equal?(@server)
    inbox = @inbox[endpoint]
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    types = Array(type)
    loop do
      index = inbox.index do |event|
        types.include?(event[1]) && (id.nil? || event[0] == id) &&
          (connection.nil? || event[3] == connection)
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
