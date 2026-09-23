# frozen_string_literal: true

require "test_helper"

class WebTransportStreamTest < Minitest::Test
  WT = Quicsilver::Protocol::WebTransport

  # Records what reaches the transport, so tests assert on what the peer would
  # see rather than on internal flags.
  class RecordingTransport
    attr_reader :resets, :stops, :writes, :deferred

    def initialize
      @resets = []
      @stops = []
      @writes = []
      @deferred = []
    end

    def abort(code) = @resets << code
    def stop_sending(code) = @stops << code
    def send(data, fin: false) = @writes << [data, fin]
    def handle = 99_999
    def grant_receive_credit(bytes, chunks) = true
    def defer_receive(bytes)
      @deferred << bytes
      true
    end
  end

  # === Application error codes (draft-16 §4.4) ===
  #
  #   The error code from a WebTransport stream reset MUST be delivered
  #   unchanged ... by endpoints delivering to the application.
  #
  # Codes share the HTTP/3 space, so they are mapped into the reserved
  # WT_APPLICATION_ERROR range going out and back again coming in.

  def test_reset_maps_the_application_code_onto_the_wire
    transport = RecordingTransport.new

    stream_on(transport).reset(42)

    assert_equal [WT.application_error_to_http(42)], transport.resets
  end

  def test_reset_closes_the_stream
    stream = stream_on(RecordingTransport.new)

    stream.reset(42)

    refute stream.open?
  end

  def test_reset_on_an_already_closed_stream_sends_nothing
    transport = RecordingTransport.new
    stream = stream_on(transport)
    stream.notify_close

    stream.reset(42)

    assert_empty transport.resets
  end

  def test_a_peer_reset_reports_the_application_code
    stream = stream_on(RecordingTransport.new)
    received = nil
    stream.on_peer_reset { |code| received = code }

    stream.notify_peer_reset(WT.application_error_to_http(42))

    assert_equal 42, received
  end

  def test_each_signal_reaches_its_own_callback
    stream = stream_on(RecordingTransport.new)
    received = []
    stream.on_peer_reset { |code| received << [:reset, code] }
    stream.on_peer_stop_sending { |code| received << [:stop_sending, code] }

    stream.notify_peer_reset(WT.application_error_to_http(42))
    stream.notify_peer_stop_sending(WT.application_error_to_http(43))

    assert_equal [[:reset, 42], [:stop_sending, 43]], received
  end

  def test_stop_sending_does_not_invoke_the_reset_callback
    stream = stream_on(RecordingTransport.new)
    stream.on_peer_reset { flunk "reset callback ran for STOP_SENDING" }

    stream.notify_peer_stop_sending(WT.application_error_to_http(42))
  end

  def test_a_peer_stop_sending_outside_the_range_reports_no_code
    stream = stream_on(RecordingTransport.new)
    received = :unset
    stream.on_peer_stop_sending { |code| received = code }

    stream.notify_peer_stop_sending(Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    assert_nil received
  end

  # §4.4: a code outside the reserved range is still a reset, but carries no
  # application code.
  def test_a_peer_reset_outside_the_range_reports_no_code
    stream = stream_on(RecordingTransport.new)
    received = :unset
    stream.on_peer_reset { |code| received = code }

    stream.notify_peer_reset(Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    assert_nil received
  end

  def test_a_peer_reset_keeps_the_write_side_open
    transport = RecordingTransport.new
    stream = stream_on(transport)

    stream.notify_peer_reset(Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    assert stream.open?
    assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    stream.write("response")
    stream.close_write
    assert_equal [["response", false], ["", true]], transport.writes
    refute stream.open?
  end

  def stream_on(transport, **options)
    Quicsilver::Server::WebTransportStream.new(
      session: nil, stream: transport, stream_id: 4, **options
    )
  end

  # A FIN can arrive after the read side is already closed, and a write racing
  # that close lands in receive_data's rescue. Neither may re-close the half or
  # fire on_close twice.
  def test_receive_fin_after_the_read_side_closed_is_a_no_op
    stream = stream_on(RecordingTransport.new)
    closes = 0
    stream.on_close { closes += 1 }
    stream.notify_read_close
    stream.close_write

    stream.receive_fin("late")

    assert_equal 1, closes
    assert_nil stream.read
  end

  def test_receive_data_reports_no_consumption_when_the_write_races_a_close
    stream = stream_on(RecordingTransport.new)
    stream.instance_variable_get(:@input).define_singleton_method(:write) do |_chunk|
      # The reader closes the stream while this write is in flight.
      stream.instance_variable_set(:@read_open, false)
      raise ::Protocol::HTTP::Body::Writable::Closed
    end

    refute stream.receive_data("late"), "a swallowed close must not report consumption"
  end

  def test_backpressure_preserves_the_final_suffix_until_it_can_be_read
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 4, receive_backpressure: true)

    stream.receive_fin("123456")
    assert_equal "1234", stream.read
    assert_equal [2], transport.deferred
    assert_empty transport.resets

    stream.receive_fin("56")
    assert_equal "56", stream.read
    assert_nil stream.read
  end

  def test_reset_discards_input_while_backpressure_has_deferred_a_suffix
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 4, receive_backpressure: true)
    stream.receive_data("123456")

    stream.notify_peer_reset(WT.application_error_to_http(42))

    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    assert_equal 42, error.application_error_code
  end

  def test_failed_receive_credit_grant_closes_the_stream_instead_of_hanging
    transport = RecordingTransport.new
    def transport.grant_receive_credit(bytes, chunks) = false
    stream = stream_on(transport, receive_backpressure: true, receive_overflow_code: 42)

    stream.receive_data("data")

    assert_equal [WT.application_error_to_http(42)], transport.resets
    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    assert_equal 42, error.application_error_code
  end

  def test_failed_credit_grant_wakes_reader_even_when_native_abort_raises
    transport = RecordingTransport.new
    def transport.grant_receive_credit(bytes, chunks) = false
    def transport.abort(code) = raise IOError, "native abort failed"
    stream = stream_on(transport, receive_backpressure: true, receive_overflow_code: 42)

    assert_raises(IOError) { stream.receive_data("data") }

    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    assert_equal 42, error.application_error_code
    refute stream.open?
  end

  def test_receive_byte_limit_stops_only_the_overflowing_stream
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 4, receive_overflow_code: 42)
    other = stream_on(RecordingTransport.new)

    stream.receive_data("1234")
    stream.receive_data("5")
    stream.receive_data("late")
    other.receive_data("usable")
    other.notify_read_close

    assert_equal [WT.application_error_to_http(42)], transport.stops
    assert_empty transport.resets
    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    assert_equal 42, error.application_error_code
    assert_equal "usable", other.read
    assert_nil other.read
  end

  # Overflow is a reader problem; the app can still answer on the write half.
  def test_receive_overflow_keeps_the_write_side_open
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 4, receive_overflow_code: 42)

    stream.receive_data("12345")

    assert stream.open?
    stream.write("too much input")
    assert_equal [["too much input", false]], transport.writes
    stream.close_write
    refute stream.open?
  end

  def test_receive_larger_than_byte_limit_stops_an_empty_stream
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 4, receive_overflow_code: 42)

    stream.receive_data("12345")

    assert_equal [WT.application_error_to_http(42)], transport.stops
    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    assert_equal 42, error.application_error_code
  end

  def test_receive_chunk_limit_counts_tiny_chunks_but_not_empty_data
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_chunks: 2)
    stream.receive_data("")
    stream.receive_data("a")
    stream.receive_data("b")
    assert_empty transport.stops
    stream.receive_data("c")
    assert_equal 1, transport.stops.size
    assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
  end

  def test_read_releases_receive_capacity_and_fin_preserves_queued_bytes
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 4, receive_buffer_chunks: 1)
    stream.receive_data("1234")
    assert_equal "1234", stream.read
    stream.receive_data("5678")
    stream.notify_read_close

    assert_equal "5678", stream.read
    assert_nil stream.read
    assert_empty transport.resets
  end

  def test_receive_limits_must_be_positive_integers
    [0, -1, nil, 1.5].each do |limit|
      assert_raises(ArgumentError) { stream_on(RecordingTransport.new, receive_buffer_bytes: limit) }
      assert_raises(ArgumentError) { stream_on(RecordingTransport.new, receive_buffer_chunks: limit) }
    end
  end

  def test_receive_overflow_discards_input_even_if_native_abort_raises
    transport = RecordingTransport.new
    stream = stream_on(transport, receive_buffer_bytes: 1)
    stream.receive_data("a")

    transport.stub(:stop_sending, ->(*) { raise IOError, "Transport failed" }) do
      assert_raises(IOError) { stream.receive_data("b") }
    end

    assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
  end

  def test_received_chunks_are_read_in_order_before_eof
    stream = build_stream
    stream.receive_data("one")
    stream.receive_data("two")
    stream.notify_read_close

    assert_equal "one", stream.read
    assert_equal "two", stream.read
    assert_nil stream.read
    assert stream.open?
  end

  def test_receive_data_ignores_empty_chunks
    stream = build_stream
    stream.receive_data("")
    stream.notify_read_close

    assert_nil stream.read
  end

  def test_notify_read_close_invokes_close_callback_without_closing_write_side
    stream = build_stream
    closed = false

    stream.on_close { closed = true }
    stream.notify_read_close

    assert closed
    assert stream.open?, "peer FIN should not close local write side"
  end

  # === Lifecycle ===

  def test_open_by_default
    assert build_stream.open?
  end

  def test_close_makes_stream_not_open
    stream = build_stream(:closeable)
    stream.close
    refute stream.open?
  end

  def test_notify_close_closes
    stream = build_stream
    stream.notify_close
    refute stream.open?
  end

  def test_notify_close_invokes_close_callback
    stream = build_stream
    closed = false

    stream.on_close { closed = true }
    stream.notify_close

    assert closed
  end

  def test_close_callback_only_runs_once
    stream = build_stream
    closed = 0

    stream.on_close { closed += 1 }
    stream.notify_read_close
    stream.notify_close

    assert_equal 1, closed
  end

  def test_close_after_peer_read_close_still_sends_fin
    stream = build_stream(:closeable)

    stream.notify_read_close
    stream.close

    refute stream.open?
  end

  def test_write_on_closed_stream_raises
    stream = build_stream(:closeable)
    stream.close
    assert_raises(IOError) { stream.write("late") }
  end

  def test_write_after_close_write_raises
    stream = build_stream(:closeable)
    stream.close_write

    assert_raises(IOError) { stream.write("late") }
  end

  def test_failed_fin_is_reported_and_can_be_retried
    transport = RecordingTransport.new
    stream = stream_on(transport)
    transport.stub(:send, ->(*) { raise IOError, "send failed" }) do
      assert_raises(IOError) { stream.close_write }
    end

    stream.close_write
    assert_equal [["".b, true]], transport.writes
    assert_empty transport.stops
  end

  def test_close_sends_fin_and_requests_peer_to_stop_once
    transport = RecordingTransport.new
    stream = stream_on(transport)
    2.times { stream.close }

    assert_equal [["".b, true]], transport.writes
    assert_equal [WT.application_error_to_http(0)], transport.stops
  end

  def test_close_stops_receiving_even_when_fin_fails
    transport = RecordingTransport.new
    stream = stream_on(transport)
    stream.receive_data("unread")
    transport.stub(:send, ->(*) { raise IOError, "send failed" }) do
      assert_raises(IOError) { stream.close }
    end

    assert_equal [WT.application_error_to_http(0)], transport.stops
    assert_nil stream.read
  end

  def test_close_receive_only_stream_only_requests_peer_to_stop
    transport = RecordingTransport.new
    stream = Quicsilver::Server::WebTransportStream.new(
      session: nil, stream: transport, stream_id: 2, direction: :receive_only
    )
    stream.close

    assert_empty transport.writes
    assert_equal [WT.application_error_to_http(0)], transport.stops
  end

  def test_close_send_only_stream_only_sends_fin
    transport = RecordingTransport.new
    stream = Quicsilver::Server::WebTransportStream.new(
      session: nil, stream: transport, stream_id: 3, direction: :send_only
    )
    stream.close

    assert_equal [["".b, true]], transport.writes
    assert_empty transport.stops
  end

  def test_close_after_peer_fin_does_not_request_peer_to_stop
    transport = RecordingTransport.new
    stream = stream_on(transport)
    stream.notify_read_close
    stream.close

    assert_equal [["".b, true]], transport.writes
    assert_empty transport.stops
  end

  def test_write_sends_raw_bytes
    raw = Minitest::Mock.new
    raw.expect(:send, true, ["hello"])

    stream = Quicsilver::Server::WebTransportStream.new(
      session: Minitest::Mock.new, stream: raw, stream_id: 4
    )
    stream.write("hello")

    raw.verify
  end

  # === Direction enforcement ===

  def test_bidi_stream_receives_data
    stream = build_stream
    stream.receive_data("hello")
    assert_equal "hello", stream.read
  end

  def test_receive_only_stream_raises_on_write
    stream = build_stream(:receive_only)
    assert_raises(RuntimeError) { stream.write("nope") }
  end

  def test_receive_only_stream_receives_data
    stream = build_stream(:receive_only)
    stream.receive_data("from client")
    assert_equal "from client", stream.read
  end

  def test_send_only_stream_rejects_reads
    stream = Quicsilver::Server::WebTransportStream.new(
      session: nil, stream: RecordingTransport.new, stream_id: 3, direction: :send_only
    )
    assert_raises(IOError) { stream.read }
  end

  def test_clean_native_shutdown_preserves_unread_bytes
    stream = build_stream
    stream.receive_data("last")
    stream.notify_read_close
    stream.notify_close

    assert_equal "last", stream.read
    assert_nil stream.read
  end

  def test_local_close_discards_unread_bytes
    stream = build_stream(:closeable)
    stream.receive_data("unread")
    stream.close

    assert_nil stream.read
  end

  def test_reset_discards_bytes_and_reports_both_error_codes
    stream = build_stream
    stream.receive_data("unread")
    code = WT.application_error_to_http(42)
    stream.notify_peer_reset(code)

    error = assert_raises(Quicsilver::Server::WebTransportStream::ResetError) { stream.read }
    assert_equal 42, error.application_error_code
    assert_equal code, error.http_error_code
  end

  def test_session_abort_wakes_reader_with_protocol_error
    stream = stream_on(RecordingTransport.new)
    entered = Queue.new
    reader = Thread.new do
      entered << true
      stream.read
    rescue Quicsilver::Server::WebTransportStream::ResetError => error
      error
    end
    assert entered.pop(timeout: 2)
    stream.abort(WT::SESSION_GONE)
    assert reader.join(2)
    assert_equal WT::SESSION_GONE, reader.value.http_error_code
    assert_nil reader.value.application_error_code
  ensure
    reader&.kill
    reader&.join(2)
  end

  def test_fin_wakes_reader_with_eof
    stream = build_stream
    entered = Queue.new
    reader = Thread.new { entered << true; stream.read }
    assert entered.pop(timeout: 2)
    stream.notify_read_close
    assert reader.join(2)
    assert_nil reader.value
  ensure
    reader&.kill
    reader&.join(2)
  end

  def test_concurrent_receive_preserves_fifo_for_a_slow_reader
    stream = build_stream
    stream.receive_data("old")
    started = Queue.new
    continue = Queue.new
    reader = Thread.new do
      first = stream.read
      started << true
      continue.pop
      [first, stream.read, stream.read]
    end
    assert started.pop(timeout: 2)
    stream.receive_data("new")
    stream.notify_read_close
    continue << true
    assert reader.join(2)
    assert_equal ["old", "new", nil], reader.value
  ensure
    continue&.push(true)
    reader&.kill
    reader&.join(2)
  end

  def test_read_close_keeps_send_side_usable
    transport = Minitest::Mock.new
    transport.expect(:send, true, ["reply"])
    stream = stream_on(transport)
    stream.notify_read_close

    assert_nil stream.read
    stream.write("reply")
    transport.verify
  end

  def test_write_close_keeps_receive_side_usable
    stream = build_stream(:closeable)
    stream.close_write
    stream.receive_data("reply")
    stream.notify_read_close

    assert_equal "reply", stream.read
    assert_nil stream.read
    refute stream.open?
  end

  private

  def build_stream(variant = :bidi)
    Quicsilver::Server::WebTransportStream.new(
      session: nil, stream: RecordingTransport.new, stream_id: 4,
      direction: variant == :receive_only ? :receive_only : :bidi
    )
  end
end
