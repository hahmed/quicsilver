# frozen_string_literal: true

require "test_helper"

class WebTransportStreamTest < Minitest::Test

  # === Receiving data ===

  def test_receive_data_invokes_callback_with_raw_bytes
    stream = build_stream
    received = []

    stream.on_data { |data| received << data }
    stream.receive_data("hello")

    assert_equal ["hello"], received
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
