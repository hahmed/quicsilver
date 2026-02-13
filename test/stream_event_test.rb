# frozen_string_literal: true

require "test_helper"

class StreamEventTest < Minitest::Test
  def test_receive_fin_extracts_handle_and_data
    handle = 0xCAFEBABE
    payload = "HTTP/3 response data"
    raw = [handle].pack("Q") + payload

    event = Quicsilver::StreamEvent.new(raw, "RECEIVE_FIN")

    assert_equal handle, event.handle
    assert_equal payload, event.data
    assert_nil event.error_code
  end

  def test_receive_fin_with_empty_payload
    handle = 123
    raw = [handle].pack("Q")

    event = Quicsilver::StreamEvent.new(raw, "RECEIVE_FIN")

    assert_equal handle, event.handle
    assert_equal "".b, event.data
  end

  def test_stream_reset_extracts_handle_and_error_code
    handle = 0xDEADBEEF
    error_code = 0x10c
    raw = [handle, error_code].pack("QQ")

    event = Quicsilver::StreamEvent.new(raw, "STREAM_RESET")

    assert_equal handle, event.handle
    assert_equal error_code, event.error_code
    assert_nil event.data
  end

  def test_stop_sending_extracts_handle_and_error_code
    handle = 0xFEEDFACE
    error_code = 0x0108
    raw = [handle, error_code].pack("QQ")

    event = Quicsilver::StreamEvent.new(raw, "STOP_SENDING")

    assert_equal handle, event.handle
    assert_equal error_code, event.error_code
    assert_nil event.data
  end

  def test_receive_fin_with_binary_payload
    handle = 42
    payload = "\x00\x01\x02\xFF".b
    raw = [handle].pack("Q") + payload

    event = Quicsilver::StreamEvent.new(raw, "RECEIVE_FIN")

    assert_equal handle, event.handle
    assert_equal payload, event.data
  end

  def test_handle_is_always_extracted_regardless_of_event_type
    handle = 99999
    raw = [handle, 0].pack("QQ")

    %w[RECEIVE_FIN STREAM_RESET STOP_SENDING].each do |type|
      event = Quicsilver::StreamEvent.new(raw, type)
      assert_equal handle, event.handle, "Handle should be extracted for #{type}"
    end
  end
end
