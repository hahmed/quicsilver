# frozen_string_literal: true

require "test_helper"

class QuicStreamTest < Minitest::Test
  def test_initializes_with_stringio_buffer
    stream = Quicsilver::QuicStream.new(0)
    assert_instance_of StringIO, stream.buffer
  end

  def test_append_data_uses_write_not_concatenation
    stream = Quicsilver::QuicStream.new(0)

    stream.append_data("chunk1")
    stream.append_data("chunk2")
    stream.append_data("chunk3")

    assert_equal "chunk1chunk2chunk3", stream.data
  end

  def test_data_returns_buffer_as_string
    stream = Quicsilver::QuicStream.new(0)
    stream.append_data("hello")

    assert_instance_of String, stream.data
    assert_equal "hello", stream.data
  end

  def test_append_data_handles_binary_data
    stream = Quicsilver::QuicStream.new(0)
    binary = "\x00\x01\x02\xFF\xFE".b

    stream.append_data(binary)
    stream.append_data(binary)

    assert_equal binary + binary, stream.data
  end

  def test_clear_buffer_resets_position_and_content
    stream = Quicsilver::QuicStream.new(0)
    stream.append_data("some data")

    stream.clear_buffer

    assert_equal 0, stream.buffer.pos
    assert_equal 0, stream.buffer.size
  end

  def test_large_buffer_accumulation_no_memory_explosion
    stream = Quicsilver::QuicStream.new(0)
    chunk = "x" * 1024  # 1KB chunk

    # Simulate 1000 chunks (1MB total) - should not create 1000 intermediate strings
    1000.times { stream.append_data(chunk) }

    assert_equal 1024 * 1000, stream.data.bytesize
  end

  def test_bidirectional_stream_detection
    # Bidirectional streams have bit 1 unset
    assert Quicsilver::QuicStream.new(0).bidirectional?
    assert Quicsilver::QuicStream.new(4).bidirectional?

    # Unidirectional streams have bit 1 set
    refute Quicsilver::QuicStream.new(2).bidirectional?
    refute Quicsilver::QuicStream.new(3).bidirectional?
  end

  def test_ready_to_send_requires_stream_handle
    stream = Quicsilver::QuicStream.new(0)
    refute stream.ready_to_send?

    stream.stream_handle = 12345
    assert stream.ready_to_send?
  end
end
