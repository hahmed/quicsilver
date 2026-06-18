# frozen_string_literal: true

require "test_helper"

class CloseWriteTest < Minitest::Test
  def test_transport_stream_close_write_sends_fin
    handle = Object.new
    stream = Quicsilver::Transport::Stream.new(handle)
    called = nil

    Quicsilver.stub(:send_stream, ->(*args) { called = args; true }) do
      stream.close_write
    end

    assert_same handle, called[0]
    assert_equal "".b, called[1]
    assert_equal true, called[2]
  end

  def test_inbound_stream_close_write_sends_fin_when_writable
    stream = Quicsilver::Transport::InboundStream.new(4)
    handle = Object.new
    stream.stream_handle = handle
    called = nil

    Quicsilver.stub(:send_stream, ->(*args) { called = args; true }) do
      stream.close_write
    end

    assert_same handle, called[0]
    assert_equal "".b, called[1]
    assert_equal true, called[2]
  end

  def test_inbound_stream_close_write_noops_when_not_writable
    stream = Quicsilver::Transport::InboundStream.new(4)

    Quicsilver.stub(:send_stream, ->(*) { raise "should not send" }) do
      assert_nil stream.close_write
    end
  end
end
