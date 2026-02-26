# frozen_string_literal: true

require "test_helper"

class StreamEventTest < Minitest::Test
  def test_receive_fin_extracts_handle_and_data
    payload = "HTTP/3 response data"
    event = build_receive_fin(0xCAFEBABE, payload)

    assert_equal 0xCAFEBABE, event.handle
    assert_equal payload, event.data
    assert_nil event.error_code
  end

  def test_receive_fin_with_empty_payload
    event = build_receive_fin(123)

    assert_equal 123, event.handle
    assert_equal "".b, event.data
  end

  def test_stream_reset_extracts_handle_and_error_code
    event = build_error_event(0xDEADBEEF, 0x10c, "STREAM_RESET")

    assert_equal 0xDEADBEEF, event.handle
    assert_equal 0x10c, event.error_code
    assert_nil event.data
  end

  def test_stop_sending_extracts_handle_and_error_code
    event = build_error_event(0xFEEDFACE, 0x0108, "STOP_SENDING")

    assert_equal 0xFEEDFACE, event.handle
    assert_equal 0x0108, event.error_code
    assert_nil event.data
  end

  def test_receive_fin_with_binary_payload
    payload = "\x00\x01\x02\xFF".b
    event = build_receive_fin(42, payload)

    assert_equal 42, event.handle
    assert_equal payload, event.data
  end

  def test_handle_is_always_extracted_regardless_of_event_type
    handle = 99999

    assert_equal handle, build_receive_fin(handle).handle
    assert_equal handle, build_error_event(handle, 0, "STREAM_RESET").handle
    assert_equal handle, build_error_event(handle, 0, "STOP_SENDING").handle
  end

  private

  # Mirrors C extension RECEIVE_FIN format: [handle(8)][payload...]
  def build_receive_fin(handle, payload = "".b)
    raw = [handle].pack("Q") + payload.b
    Quicsilver::Transport::StreamEvent.new(raw, "RECEIVE_FIN")
  end

  # Mirrors C extension STREAM_RESET/STOP_SENDING format: [handle(8)][error_code(8)]
  def build_error_event(handle, error_code, type)
    raw = [handle, error_code].pack("QQ")
    Quicsilver::Transport::StreamEvent.new(raw, type)
  end
end
