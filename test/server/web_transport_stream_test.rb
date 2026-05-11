# frozen_string_literal: true

require "test_helper"

class WebTransportStreamTest < Minitest::Test
  def test_stream_receives_data_frames
    stream = build_stream
    received = nil
    stream.on_data { |data| received = data }

    # Simulate a DATA frame: type(1) + length(1) + payload
    frame = Quicsilver::Protocol.build_frame(Quicsilver::Protocol::FRAME_DATA, "hello")
    stream.receive_data(frame)

    assert_equal "hello", received
  end

  def test_stream_receives_multiple_frames
    stream = build_stream
    chunks = []
    stream.on_data { |data| chunks << data }

    frame1 = Quicsilver::Protocol.build_frame(Quicsilver::Protocol::FRAME_DATA, "one")
    frame2 = Quicsilver::Protocol.build_frame(Quicsilver::Protocol::FRAME_DATA, "two")
    stream.receive_data(frame1 + frame2)

    assert_equal %w[one two], chunks
  end

  def test_stream_handles_partial_frames
    stream = build_stream
    chunks = []
    stream.on_data { |data| chunks << data }

    frame = Quicsilver::Protocol.build_frame(Quicsilver::Protocol::FRAME_DATA, "complete")
    # Split in the middle
    stream.receive_data(frame.byteslice(0, 3))
    assert_empty chunks

    stream.receive_data(frame.byteslice(3..-1))
    assert_equal ["complete"], chunks
  end

  def test_stream_open_by_default
    stream = build_stream
    assert stream.open?
  end

  def test_notify_close_fires_callback
    stream = build_stream
    closed = false
    stream.on_close { closed = true }
    stream.notify_close

    assert closed
    refute stream.open?
  end

  def test_session_add_stream_fires_callback
    session = build_session
    received_stream = nil
    session.on_stream { |s| received_stream = s }

    session.add_stream(99999, 8)

    assert_kind_of Quicsilver::Server::WebTransportStream, received_stream
    assert_equal 8, received_stream.stream_id
  end

  def test_session_remove_stream_notifies_close
    session = build_session
    closed = false
    session.on_stream { |s| s.on_close { closed = true } }
    session.add_stream(99999, 8)

    session.remove_stream(8)
    assert closed
  end

  def test_session_notify_close_closes_all_streams
    session = build_session
    closed_count = 0
    session.on_stream { |s| s.on_close { closed_count += 1 } }
    session.add_stream(99999, 4)
    session.add_stream(99999, 8)

    session.notify_close
    assert_equal 2, closed_count
  end

  private

  def build_stream
    session = Minitest::Mock.new
    stream = Minitest::Mock.new
    Quicsilver::Server::WebTransportStream.new(
      session: session, stream: stream, stream_id: 4
    )
  end

  def build_session
    connection = Minitest::Mock.new
    stream = Minitest::Mock.new
    stream.expect(:stream_id, 0)
    stream.expect(:stream_handle, 99999)

    Quicsilver::Server::WebTransportSession.new(
      connection: connection, stream: stream,
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "localhost:4433", ":path" => "/cable"
      }
    )
  end
end
