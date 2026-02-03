# frozen_string_literal: true

require "test_helper"

class StreamResetTest < Minitest::Test
  def test_http3_error_codes_defined
    # RFC 9114 Section 8.1 error codes
    assert_equal 0x100, Quicsilver::HTTP3::H3_NO_ERROR
    assert_equal 0x101, Quicsilver::HTTP3::H3_GENERAL_PROTOCOL_ERROR
    assert_equal 0x102, Quicsilver::HTTP3::H3_INTERNAL_ERROR
    assert_equal 0x103, Quicsilver::HTTP3::H3_STREAM_CREATION_ERROR
    assert_equal 0x104, Quicsilver::HTTP3::H3_CLOSED_CRITICAL_STREAM
    assert_equal 0x105, Quicsilver::HTTP3::H3_FRAME_UNEXPECTED
    assert_equal 0x106, Quicsilver::HTTP3::H3_FRAME_ERROR
    assert_equal 0x107, Quicsilver::HTTP3::H3_EXCESSIVE_LOAD
    assert_equal 0x108, Quicsilver::HTTP3::H3_ID_ERROR
    assert_equal 0x109, Quicsilver::HTTP3::H3_SETTINGS_ERROR
    assert_equal 0x10a, Quicsilver::HTTP3::H3_MISSING_SETTINGS
    assert_equal 0x10b, Quicsilver::HTTP3::H3_REQUEST_REJECTED
    assert_equal 0x10c, Quicsilver::HTTP3::H3_REQUEST_CANCELLED
    assert_equal 0x10d, Quicsilver::HTTP3::H3_REQUEST_INCOMPLETE
    assert_equal 0x10e, Quicsilver::HTTP3::H3_MESSAGE_ERROR
    assert_equal 0x10f, Quicsilver::HTTP3::H3_CONNECT_ERROR
    assert_equal 0x110, Quicsilver::HTTP3::H3_VERSION_FALLBACK
  end

  def test_qpack_error_codes_defined
    # RFC 9204 Section 6 error codes
    assert_equal 0x200, Quicsilver::HTTP3::QPACK_DECOMPRESSION_FAILED
    assert_equal 0x201, Quicsilver::HTTP3::QPACK_ENCODER_STREAM_ERROR
    assert_equal 0x202, Quicsilver::HTTP3::QPACK_DECODER_STREAM_ERROR
  end

  def test_server_stream_event_constants
    assert_equal "STREAM_RESET", Quicsilver::Server::STREAM_EVENT_STREAM_RESET
    assert_equal "STOP_SENDING", Quicsilver::Server::STREAM_EVENT_STOP_SENDING
  end

  def test_client_stream_reset_error_class
    error = Quicsilver::Client::StreamResetError.new("test", 0x10c)
    assert_equal 0x10c, error.error_code
    assert_includes error.message, "0x10c"
    assert_includes error.message, "test"
  end

  def test_client_stream_reset_error_default_code
    error = Quicsilver::Client::StreamResetError.new("test")
    assert_equal 0, error.error_code
  end

end
