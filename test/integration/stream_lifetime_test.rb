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
    attr_accessor :receive_callback

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
        @receive_callback&.call(stream_id, event, data) if %w[RECEIVE RECEIVE_FIN].include?(event)
        @events << [stream_id, event, data, connection.first]
        return
      end

      super
      if %w[CONNECTION_CLOSED STREAM_START_COMPLETE STREAM_SHUTDOWN_COMPLETE].include?(event)
        @events << [stream_id, event, data, connection.first]
      end
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

  def test_stop_sending_retires_a_webtransport_stream_with_paused_input
    session = accept_backpressured_session
    accepted = Queue.new
    session.on_stream { |stream| accepted << stream }
    connection = @client.instance_variable_get(:@connection_data)
    outgoing = Quicsilver::Transport::Stream.new(Quicsilver.open_stream(connection, false))
    prefix = Quicsilver::Protocol.encode_varint(session.class::WT_STREAM_BIDI) +
      Quicsilver::Protocol.encode_varint(session.stream_id)
    outgoing.send(prefix + "abcdefghij")
    incoming = accepted.pop(timeout: 3)
    refute_nil incoming, "WebTransport child was not accepted"
    id = incoming.stream_id
    code = Quicsilver::Protocol::WebTransport.application_error_to_http(42)

    assert outgoing.stop_sending(code)
    stopped = await_event(@client, "STOP_SENDING", id)
    assert_equal code, decode_event(stopped).error_code
    await_event(@server, "STREAM_SHUTDOWN_COMPLETE", id, connection: session.connection.handle)
    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { incoming.read }
    assert_equal 42, error.application_error_code
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


  def accept_backpressured_session
    _, connect_stream, = open_stream
    session = Quicsilver::Server::WebTransportSession.new(
      connection: @server_connection, stream: connect_stream, headers: {}
    )
    @server.instance_variable_get(:@webtransport).for(@server_connection.handle).register(session)
    session.accept!(receive_backpressure: true, receive_buffer_bytes: 4, receive_buffer_chunks: 1)
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

    other = RecordingClient.new("localhost", @port, unsecure: true, request_timeout: 3)
    assert_equal 200, other.get("/").status

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
