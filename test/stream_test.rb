# frozen_string_literal: true

require "test_helper"

class StreamTest < Minitest::Test
  def setup
    @stream = Quicsilver::Stream.new(42)
  end

  def test_handle
    assert_equal 42, @stream.handle
  end

  def test_send_delegates_to_quicsilver
    called_with = nil
    Quicsilver.stub(:send_stream, ->(*args) { called_with = args; true }) do
      @stream.send("hello", fin: true)
    end
    assert_equal [42, "hello", true], called_with
  end

  def test_send_defaults_fin_to_false
    called_with = nil
    Quicsilver.stub(:send_stream, ->(*args) { called_with = args; true }) do
      @stream.send("data")
    end
    assert_equal [42, "data", false], called_with
  end

  def test_reset_delegates_to_quicsilver
    called_with = nil
    Quicsilver.stub(:stream_reset, ->(*args) { called_with = args; true }) do
      @stream.reset
    end
    assert_equal [42, Quicsilver::HTTP3::H3_REQUEST_CANCELLED], called_with
  end

  def test_reset_accepts_custom_error_code
    called_with = nil
    Quicsilver.stub(:stream_reset, ->(*args) { called_with = args; true }) do
      @stream.reset(0x999)
    end
    assert_equal [42, 0x999], called_with
  end

  def test_stop_sending_delegates_to_quicsilver
    called_with = nil
    Quicsilver.stub(:stream_stop_sending, ->(*args) { called_with = args; true }) do
      @stream.stop_sending
    end
    assert_equal [42, Quicsilver::HTTP3::H3_REQUEST_CANCELLED], called_with
  end

  def test_stop_sending_accepts_custom_error_code
    called_with = nil
    Quicsilver.stub(:stream_stop_sending, ->(*args) { called_with = args; true }) do
      @stream.stop_sending(0x42)
    end
    assert_equal [42, 0x42], called_with
  end
end
