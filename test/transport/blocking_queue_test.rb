# frozen_string_literal: true

require "test_helper"

class BlockingQueueTest < Minitest::Test
  def test_pop_returns_pushed_item
    queue = Quicsilver::Transport::BlockingQueue.new
    queue.push("hello")

    assert_equal "hello", queue.pop
  end

  def test_pop_blocks_until_item_is_pushed
    queue = Quicsilver::Transport::BlockingQueue.new
    reader = Thread.new { queue.pop }

    refute reader.join(0.01)
    queue.push("hello")

    assert_equal "hello", reader.value
  end

  def test_close_unblocks_pop_with_nil
    queue = Quicsilver::Transport::BlockingQueue.new
    reader = Thread.new { queue.pop }

    refute reader.join(0.01)
    queue.close

    assert_nil reader.value
  end

  def test_push_returns_false_after_close
    queue = Quicsilver::Transport::BlockingQueue.new
    queue.close

    refute queue.push("hello")
  end

  def test_close_is_idempotent
    queue = Quicsilver::Transport::BlockingQueue.new

    assert queue.close
    refute queue.close
  end
end
