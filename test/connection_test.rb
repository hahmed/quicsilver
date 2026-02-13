# frozen_string_literal: true

require "test_helper"

class ConnectionTest < Minitest::Test
  def setup
    @connection = Quicsilver::Connection.new(12345, [12345, 67890])
  end

  def test_buffer_data_handles_invalid_utf8
    # StringIO.new defaults to UTF-8. Writing invalid UTF-8 bytes after
    # valid UTF-8 causes Encoding::CompatibilityError without binary encoding.
    @connection.buffer_data(1, "valid utf8")
    @connection.buffer_data(1, "\xFF\xFE".b)
    result = @connection.complete_stream(1, "".b)

    assert_equal "valid utf8\xFF\xFE".b, result.b
  end

  def test_buffer_data_accumulates_binary_chunks
    chunk1 = "\x00\x01\x02".b
    chunk2 = "\xFF\xFE\xFD".b

    @connection.buffer_data(1, chunk1)
    @connection.buffer_data(1, chunk2)
    result = @connection.complete_stream(1, "".b)

    assert_equal (chunk1 + chunk2), result.b
  end

  def test_complete_stream_with_binary_final_data
    @connection.buffer_data(1, "\x01\x02".b)
    result = @connection.complete_stream(1, "\x03\x04".b)

    assert_equal "\x01\x02\x03\x04".b, result.b
  end
end
