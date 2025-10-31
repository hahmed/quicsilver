# frozen_string_literal: true

require "test_helper"
require_relative "../lib/quicsilver/http3"

class HTTP3Test < Minitest::Test
  def test_encode_varint_small_values
    # 0-63: single byte with value directly encoded
    assert_equal "\x00".b, Quicsilver::HTTP3.encode_varint(0)
    assert_equal "\x01".b, Quicsilver::HTTP3.encode_varint(1)
    assert_equal "\x3F".b, Quicsilver::HTTP3.encode_varint(63)
  end

  def test_encode_varint_medium_values
    # 64-16383: 2 bytes starting with 0x40
    assert_equal "\x40\x40".b, Quicsilver::HTTP3.encode_varint(64)
    assert_equal "\x7F\xFF".b, Quicsilver::HTTP3.encode_varint(16383)
  end

  def test_encode_varint_large_values
    # 16384-1073741823: 4 bytes starting with 0x80
    assert_equal "\x80\x00\x40\x00".b, Quicsilver::HTTP3.encode_varint(16384)
    assert_equal "\xBF\xFF\xFF\xFF".b, Quicsilver::HTTP3.encode_varint(1073741823)
  end

  def test_encode_varint_very_large_values
    # 1073741824+: 8 bytes starting with 0xC0
    assert_equal "\xC0\x00\x00\x00\x40\x00\x00\x00".b, Quicsilver::HTTP3.encode_varint(1073741824)
  end

  def test_decode_varint_single_byte
    bytes = [0x25]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 37, value
    assert_equal 1, length
  end

  def test_decode_varint_two_bytes
    bytes = [0x40, 0x40]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 64, value
    assert_equal 2, length
  end

  def test_decode_varint_four_bytes
    bytes = [0x80, 0x00, 0x40, 0x00]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 16384, value
    assert_equal 4, length
  end

  def test_decode_varint_eight_bytes
    bytes = [0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 1073741824, value
    assert_equal 8, length
  end

  def test_decode_varint_with_offset
    bytes = [0xFF, 0xFF, 0x25]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 2)
    assert_equal 37, value
    assert_equal 1, length
  end

  def test_encode_decode_varint_roundtrip
    test_values = [0, 1, 63, 64, 100, 1000, 16383, 16384, 100000, 1073741823, 1073741824]

    test_values.each do |original|
      encoded = Quicsilver::HTTP3.encode_varint(original)
      bytes = encoded.bytes
      decoded, _ = Quicsilver::HTTP3.decode_varint(bytes, 0)
      assert_equal original, decoded, "Failed roundtrip for #{original}"
    end
  end

  def test_build_settings_frame_empty
    frame = Quicsilver::HTTP3.build_settings_frame({})

    assert_equal "\x04\x00".b, frame # Type 0x04, length 0
  end

  def test_build_settings_frame_with_values
    settings = {
      0x01 => 4096,  # QPACK_MAX_TABLE_CAPACITY
      0x06 => 16384  # MAX_HEADER_LIST_SIZE
    }

    frame = Quicsilver::HTTP3.build_settings_frame(settings)

    refute_empty frame
    assert_equal 0x04, frame.bytes[0]
  end

  def test_build_control_stream
    stream = Quicsilver::HTTP3.build_control_stream

    refute_empty stream
    assert_equal 0x00, stream.bytes[0]
    assert stream.bytesize > 1
  end

  def test_decode_varint_insufficient_bytes
    # First byte indicates 2-byte varint but only 1 byte available
    bytes = [0x40]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 0, value
    assert_equal 0, length
  end

  def test_decode_varint_empty_array
    bytes = []
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 0, value
    assert_equal 0, length
  end

  def test_decode_varint_offset_out_of_bounds
    bytes = [0x25]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 5)
    assert_equal 0, value
    assert_equal 0, length
  end

  def test_decode_varint_insufficient_bytes_four_byte
    # First byte indicates 4-byte varint but only 2 bytes available
    bytes = [0x80, 0x00]
    value, length = Quicsilver::HTTP3.decode_varint(bytes, 0)
    assert_equal 0, value
    assert_equal 0, length
  end
end
