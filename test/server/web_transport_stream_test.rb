# frozen_string_literal: true

require "test_helper"

class WebTransportStreamTest < Minitest::Test
  WT = Quicsilver::Protocol::WebTransport

  # Records what reaches the transport, so tests assert on what the peer would
  # see rather than on internal flags.
  class RecordingTransport
    attr_reader :resets

    def initialize = @resets = []

    def reset(code) = @resets << code
    def stop_sending(code) = nil
    def send(data, fin: false) = nil
    def handle = 99_999
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
    stream.on_reset { |code| received = code }

    stream.notify_reset(WT.application_error_to_http(42))

    assert_equal 42, received
  end

  # §4.4: a code outside the reserved range is still a reset, but carries no
  # application code.
  def test_a_peer_reset_outside_the_range_reports_no_code
    stream = stream_on(RecordingTransport.new)
    received = :unset
    stream.on_reset { |code| received = code }

    stream.notify_reset(Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    assert_nil received
  end

  def test_a_peer_reset_closes_the_stream
    stream = stream_on(RecordingTransport.new)

    stream.notify_reset(Quicsilver::Protocol::H3_REQUEST_CANCELLED)

    refute stream.open?
  end

  def stream_on(transport)
    Quicsilver::Server::WebTransportStream.new(
      session: nil, stream: transport, stream_id: 4
    )
  end

  def test_receive_data_invokes_callback_with_raw_bytes
    stream = build_stream
    received = []

    stream.on_data { |data| received << data }
    stream.receive_data("hello")

    assert_equal ["hello"], received
  end

  # accept_stream calls add_stream then receive_data on the event loop thread,
  # but add_stream's callback spawns a worker to consume the stream. Data that
  # arrives before that worker registers on_data must not be dropped.
  def test_receive_data_before_a_callback_is_registered_is_not_lost
    stream = build_stream
    received = []

    stream.receive_data("hello")
    stream.on_data { |data| received << data }

    assert_equal ["hello"], received
  end

  def test_buffered_chunks_are_delivered_in_order
    stream = build_stream
    received = []

    stream.receive_data("one")
    stream.receive_data("two")
    stream.on_data { |data| received << data }

    assert_equal ["one", "two"], received
  end

  def test_buffered_chunks_are_only_delivered_once
    stream = build_stream
    received = []
    stream.receive_data("hello")
    stream.on_data { |data| received << data }

    stream.receive_data("world")

    assert_equal ["hello", "world"], received
  end

  def test_receive_data_ignores_empty_chunks
    stream = build_stream
    received = []

    stream.on_data { |data| received << data }
    stream.receive_data("")

    assert_empty received
  end

  def test_receive_data_can_deliver_multiple_raw_chunks
    stream = build_stream
    received = []

    stream.on_data { |data| received << data }
    stream.receive_data("one")
    stream.receive_data("two")

    assert_equal ["one", "two"], received
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

  def test_write_on_closed_stream_does_nothing
    stream = build_stream(:closeable)
    stream.close
    stream.write("ignored")
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

  def test_bidi_stream_allows_write_and_data
    stream = build_stream
    received = nil

    stream.on_data { |data| received = data }
    stream.receive_data("hello")

    assert_equal "hello", received
  end

  def test_receive_only_stream_raises_on_write
    stream = build_stream(:receive_only)
    assert_raises(RuntimeError) { stream.write("nope") }
  end

  def test_receive_only_stream_receives_data
    stream = build_stream(:receive_only)
    received = nil

    stream.on_data { |data| received = data }
    stream.receive_data("from client")

    assert_equal "from client", received
  end

  private

  def build_stream(variant = :bidi)
    session = Minitest::Mock.new
    stream = Minitest::Mock.new

    case variant
    when :closeable
      stream.expect(:send, true, ["".b], fin: true)
    when :receive_only
      return Quicsilver::Server::WebTransportStream.new(
        session: session, stream: stream, stream_id: 4, direction: :receive_only
      )
    end

    Quicsilver::Server::WebTransportStream.new(
      session: session, stream: stream, stream_id: 4
    )
  end
end
