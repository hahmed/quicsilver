# frozen_string_literal: true

require "test_helper"

class DatagramQueueTest < Minitest::Test
  def test_pop_returns_pushed_datagram
    queue = Quicsilver::Transport::DatagramQueue.new
    queue.push("hello")

    assert_equal "hello", queue.pop
  end

  def test_tracks_length_and_byte_size
    queue = Quicsilver::Transport::DatagramQueue.new

    queue.push("one")
    queue.push("three")

    assert_equal 2, queue.length
    assert_equal 8, queue.byte_size

    assert_equal "one", queue.pop
    assert_equal 1, queue.length
    assert_equal 5, queue.byte_size
  end

  def test_drops_new_datagrams_when_full
    queue = Quicsilver::Transport::DatagramQueue.new(max_length: 1)

    assert queue.push("first")
    refute queue.push("second")

    assert_equal 1, queue.dropped
    assert_equal 1, queue.length
    assert_equal "first", queue.pop
  end

  def test_close_unblocks_pop_with_nil
    queue = Quicsilver::Transport::DatagramQueue.new
    reader = Thread.new { queue.pop }

    refute reader.join(0.01)
    queue.close

    assert_nil reader.value
  end

  def test_push_returns_false_after_close
    queue = Quicsilver::Transport::DatagramQueue.new
    queue.close

    refute queue.push("hello")
  end
end
