# frozen_string_literal: true

require_relative "../test_helper"
require "quicsilver/protocol/stream_input"

class Quicsilver::Protocol::StreamInputTest < Minitest::Test
  def test_concurrent_write_and_read
    input = Quicsilver::Protocol::StreamInput.new
    chunks_read = []

    reader = Thread.new do
      while (chunk = input.read)
        chunks_read << chunk
      end
    end

    sleep 0.01
    input.write("a")
    input.write("b")
    input.write("c")
    input.close_write

    reader.join(5)
    assert_equal ["a", "b", "c"], chunks_read
  end

  def test_bounded_queue_blocks_when_full
    input = Quicsilver::Protocol::StreamInput.new(nil, queue_size: 2)
    input.write("a")
    input.write("b")

    blocked = true
    writer = Thread.new do
      input.write("c")
      blocked = false
    end

    sleep 0.05
    assert blocked, "write should block when queue is full"

    assert_equal "a", input.read
    writer.join(2)
    refute blocked

    input.close_write
    assert_equal "b", input.read
    assert_equal "c", input.read
    assert_nil input.read
  end

  def test_read_timeout_raises
    input = Quicsilver::Protocol::StreamInput.new(nil, read_timeout: 0.05)
    assert_raises(Quicsilver::Protocol::StreamInput::ReadTimeout) { input.read }
  end

  def test_read_timeout_waits_for_delayed_data
    input = Quicsilver::Protocol::StreamInput.new(nil, read_timeout: 2.0)

    Thread.new do
      sleep 0.05
      input.write("delayed")
      input.close_write
    end

    assert_equal "delayed", input.read
    assert_nil input.read
  end

  def test_bounded_queue_with_timeout
    input = Quicsilver::Protocol::StreamInput.new(nil, queue_size: 1, read_timeout: 1.0)
    input.write("a")
    assert_equal "a", input.read
    input.close_write
    assert_nil input.read
  end
end
