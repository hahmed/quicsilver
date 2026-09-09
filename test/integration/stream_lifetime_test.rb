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

    def initialize(...)
      @events = Queue.new
      @test_streams = {}
      super
    end

    def handle_stream_event(connection, stream_id, event, data, early_data)
      key = [connection.first, stream_id]
      if %w[RECEIVE RECEIVE_FIN].include?(event) && Quicsilver::Transport::StreamEvent.new(data, event).data.start_with?(MARKER)
        @test_streams[key] = true
      end

      if @test_streams[key]
        @events << [stream_id, event, data]
        return
      end

      @events << [stream_id, event, data] if event == "CONNECTION_CLOSED"
      super
    end
  end

  def setup
    @inbox = Hash.new { |hash, key| hash[key] = [] }
    @port = find_available_port
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    @server = RecordingServer.new(@port, server_configuration: config, app: ->(_) { [200, {}, ["OK"]] })
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
    await_event(@server, "CONNECTION_CLOSED")

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
    Quicsilver::Transport::StreamEvent.new(event.last, event[1])
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

  def await_event(endpoint, type, id = nil)
    inbox = @inbox[endpoint]
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    types = Array(type)
    loop do
      index = inbox.index { |event| types.include?(event[1]) && (id.nil? || event[0] == id) }
      return inbox.delete_at(index) if index

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_operator remaining, :>, 0, "Timed out waiting for #{type} on #{id}"
      event = endpoint.events.pop(timeout: remaining)
      refute_nil event, "Timed out waiting for #{type} on #{id}"
      inbox << event
    end
  end
end
