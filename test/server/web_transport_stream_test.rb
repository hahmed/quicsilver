# frozen_string_literal: true

require "test_helper"

class WebTransportStreamTest < Minitest::Test

  # === Receiving data ===

  def test_read_receives_single_data_frame
    stream = build_stream
    stream.receive_data(data_frame("hello"))
    assert_equal "hello", stream.read
  end

  def test_read_receives_multiple_frames
    stream = build_stream
    stream.receive_data(data_frame("one") + data_frame("two"))
    assert_equal "one", stream.read
    assert_equal "two", stream.read
  end

  def test_read_handles_partial_frame_across_receives
    stream = build_stream
    frame = data_frame("complete")
    reader = Thread.new { stream.read }

    stream.receive_data(frame.byteslice(0, 3))
    refute reader.join(0.01)

    stream.receive_data(frame.byteslice(3..-1))
    assert_equal "complete", reader.value
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

  def test_close_unblocks_read_with_nil
    stream = build_stream(:closeable)
    stream.close
    assert_nil stream.read
  end

  def test_notify_close_unblocks_read_with_nil
    stream = build_stream
    stream.notify_close
    assert_nil stream.read
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
    stream.receive_data(data_frame("hello"))
    assert_equal "hello", stream.read
  end

  def test_receive_only_stream_raises_on_write
    stream = build_stream(:receive_only)
    assert_raises(RuntimeError) { stream.write("nope") }
  end

  def test_receive_only_stream_receives_data
    stream = build_stream(:receive_only)
    stream.receive_data(data_frame("from client"))
    assert_equal "from client", stream.read
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
      stream.expect(:close_write, true)
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
