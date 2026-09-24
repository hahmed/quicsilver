# frozen_string_literal: true

require "test_helper"

class QuicStreamTest < Minitest::Test
  parallelize_me!
  def test_initializes_with_stringio_buffer
    stream = Quicsilver::Transport::InboundStream.new(0)
    assert_instance_of StringIO, stream.buffer
  end

  def test_append_data_uses_write_not_concatenation
    stream = Quicsilver::Transport::InboundStream.new(0)

    stream.append_data("chunk1")
    stream.append_data("chunk2")
    stream.append_data("chunk3")

    assert_equal "chunk1chunk2chunk3", stream.data
  end

  def test_data_returns_buffer_as_string
    stream = Quicsilver::Transport::InboundStream.new(0)
    stream.append_data("hello")

    assert_instance_of String, stream.data
    assert_equal "hello", stream.data
  end

  def test_append_data_handles_binary_data
    stream = Quicsilver::Transport::InboundStream.new(0)
    binary = "\x00\x01\x02\xFF\xFE".b

    stream.append_data(binary)
    stream.append_data(binary)

    assert_equal binary + binary, stream.data
  end

  def test_large_buffer_accumulation_no_memory_explosion
    stream = Quicsilver::Transport::InboundStream.new(0)
    chunk = "x" * 1024  # 1KB chunk

    # Simulate 1000 chunks (1MB total) - should not create 1000 intermediate strings
    1000.times { stream.append_data(chunk) }

    assert_equal 1024 * 1000, stream.data.bytesize
  end

  def test_bidirectional_stream_detection
    # Bidirectional streams have bit 1 unset
    assert Quicsilver::Transport::InboundStream.new(0).bidirectional?
    assert Quicsilver::Transport::InboundStream.new(4).bidirectional?

    # Unidirectional streams have bit 1 set
    refute Quicsilver::Transport::InboundStream.new(2).bidirectional?
    refute Quicsilver::Transport::InboundStream.new(3).bidirectional?
  end

  def test_writable_requires_stream_handle
    stream = Quicsilver::Transport::InboundStream.new(0)
    refute stream.writable?

    stream.stream_handle = 12345
    assert stream.writable?
  end

  # NUM2ULL wraps a negative Integer into enormous credit, so the native
  # boundary rejects bad input before it is converted.
  def test_receive_credit_rejects_non_integers
    stream = Quicsilver::Transport::Stream.new(99_999)

    [1.5, nil, "4", :four].each do |value|
      assert_raises(TypeError) { stream.grant_receive_credit(value, 1) }
      assert_raises(TypeError) { stream.grant_receive_credit(1, value) }
      assert_raises(TypeError) { stream.defer_receive(value) }
    end
  end

  def test_receive_credit_rejects_negative_values
    stream = Quicsilver::Transport::Stream.new(99_999)

    assert_raises(ArgumentError) { stream.grant_receive_credit(-1, 1) }
    assert_raises(ArgumentError) { stream.grant_receive_credit(1, -1) }
    assert_raises(ArgumentError) { stream.defer_receive(-1) }
  end

  def test_receive_credit_errors_name_the_offending_argument
    stream = Quicsilver::Transport::Stream.new(99_999)

    assert_match(/chunks/, assert_raises(ArgumentError) { stream.grant_receive_credit(1, -1) }.message)
    assert_match(/Deferred/, assert_raises(TypeError) { stream.defer_receive(nil) }.message)
  end
end
