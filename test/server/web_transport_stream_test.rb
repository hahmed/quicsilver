# frozen_string_literal: true

require "test_helper"

class WebTransportStreamTest < Minitest::Test

  # === Receiving data ===

  def test_receives_single_data_frame
    stream = build_stream
    received = nil
    stream.on_data { |data| received = data }

    stream.receive_data(data_frame("hello"))
    assert_equal "hello", received
  end

  def test_receives_multiple_frames
    stream = build_stream
    chunks = []
    stream.on_data { |data| chunks << data }

    stream.receive_data(data_frame("one") + data_frame("two"))
    assert_equal %w[one two], chunks
  end

  def test_handles_partial_frame_across_receives
    stream = build_stream
    chunks = []
    stream.on_data { |data| chunks << data }

    frame = data_frame("complete")
    stream.receive_data(frame.byteslice(0, 3))
    assert_empty chunks

    stream.receive_data(frame.byteslice(3..-1))
    assert_equal ["complete"], chunks
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

  def test_close_fires_on_close_callback
    stream = build_stream(:closeable)
    closed = false
    stream.on_close { closed = true }
    stream.close
    assert closed
  end

  def test_notify_close_fires_callback_and_closes
    stream = build_stream
    closed = false
    stream.on_close { closed = true }
    stream.notify_close
    assert closed
    refute stream.open?
  end

  def test_write_on_closed_stream_does_nothing
    stream = build_stream(:closeable)
    stream.close
    # No error, just returns
    stream.write("ignored") rescue nil
  end

  # === Direction enforcement ===

  def test_bidi_stream_allows_write_and_data
    stream = build_stream
    received = nil
    stream.on_data { |data| received = data }
    stream.receive_data(data_frame("hello"))
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
    stream.receive_data(data_frame("from client"))
    assert_equal "from client", received
  end

  private

  def data_frame(payload)
    Quicsilver::Protocol.build_frame(Quicsilver::Protocol::FRAME_DATA, payload)
  end

  def build_stream(variant = :bidi)
    session = Minitest::Mock.new
    stream = Minitest::Mock.new

    case variant
    when :closeable
      stream.expect(:send, true, [String], fin: true)
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
