# frozen_string_literal: true

require "test_helper"

class HTTP3Test < Minitest::Test
  parallelize_me!
  def test_encode_varint_small_values
    # 0-63: single byte with value directly encoded
    assert_equal "\x00".b, Quicsilver::Protocol.encode_varint(0)
    assert_equal "\x01".b, Quicsilver::Protocol.encode_varint(1)
    assert_equal "\x3F".b, Quicsilver::Protocol.encode_varint(63)
  end

  def test_encode_varint_medium_values
    # 64-16383: 2 bytes starting with 0x40
    assert_equal "\x40\x40".b, Quicsilver::Protocol.encode_varint(64)
    assert_equal "\x7F\xFF".b, Quicsilver::Protocol.encode_varint(16383)
  end

  def test_encode_varint_large_values
    # 16384-1073741823: 4 bytes starting with 0x80
    assert_equal "\x80\x00\x40\x00".b, Quicsilver::Protocol.encode_varint(16384)
    assert_equal "\xBF\xFF\xFF\xFF".b, Quicsilver::Protocol.encode_varint(1073741823)
  end

  def test_encode_varint_very_large_values
    # 1073741824+: 8 bytes starting with 0xC0
    assert_equal "\xC0\x00\x00\x00\x40\x00\x00\x00".b, Quicsilver::Protocol.encode_varint(1073741824)
  end

  def test_decode_varint_single_byte
    bytes = [0x25]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 37, value
    assert_equal 1, length
  end

  def test_decode_varint_two_bytes
    bytes = [0x40, 0x40]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 64, value
    assert_equal 2, length
  end

  def test_decode_varint_four_bytes
    bytes = [0x80, 0x00, 0x40, 0x00]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 16384, value
    assert_equal 4, length
  end

  def test_decode_varint_eight_bytes
    bytes = [0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 1073741824, value
    assert_equal 8, length
  end

  def test_decode_varint_with_offset
    bytes = [0xFF, 0xFF, 0x25]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 2)
    assert_equal 37, value
    assert_equal 1, length
  end

  def test_encode_decode_varint_roundtrip
    test_values = [0, 1, 63, 64, 100, 1000, 16383, 16384, 100000, 1073741823, 1073741824]

    test_values.each do |original|
      encoded = Quicsilver::Protocol.encode_varint(original)
      bytes = encoded.bytes
      decoded, _ = Quicsilver::Protocol.decode_varint(bytes, 0)
      assert_equal original, decoded, "Failed roundtrip for #{original}"
    end
  end

  def test_build_settings_frame_empty
    frame = Quicsilver::Protocol.build_settings_frame({})

    assert_equal "\x04\x00".b, frame # Type 0x04, length 0
  end

  def test_build_settings_frame_with_values
    settings = {
      0x01 => 4096,  # QPACK_MAX_TABLE_CAPACITY
      0x06 => 16384  # MAX_HEADER_LIST_SIZE
    }

    frame = Quicsilver::Protocol.build_settings_frame(settings)

    refute_empty frame
    assert_equal 0x04, frame.bytes[0]
  end

  def test_build_control_stream
    stream = Quicsilver::Protocol.build_control_stream
    bytes = stream.bytes

    assert_equal 0x00, bytes[0]

    frame_type, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
    assert_equal 0x04, frame_type

    frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
    assert frame_length > 0, "SETTINGS frame must not be empty"

    settings_start = 1 + type_len + length_len
    settings = parse_settings(bytes[settings_start, frame_length])
    assert_equal 0, settings[0x01], "QPACK_MAX_TABLE_CAPACITY"
    assert_equal 0, settings[0x07], "QPACK_BLOCKED_STREAMS"
  end

  def test_build_control_stream_with_max_field_section_size
    stream = Quicsilver::Protocol.build_control_stream(max_field_section_size: 8192)
    bytes = stream.bytes

    assert_equal 0x00, bytes[0]

    frame_type, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
    assert_equal 0x04, frame_type

    frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
    settings_start = 1 + type_len + length_len
    settings = parse_settings(bytes[settings_start, frame_length])

    assert_equal 8192, settings[0x06], "SETTINGS_MAX_FIELD_SECTION_SIZE must be 8192"
    assert_equal 0, settings[0x01], "QPACK_MAX_TABLE_CAPACITY"
    assert_equal 0, settings[0x07], "QPACK_BLOCKED_STREAMS"
  end

  def test_build_control_stream_without_max_field_section_size
    stream = Quicsilver::Protocol.build_control_stream
    bytes = stream.bytes

    _, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
    frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
    settings = parse_settings(bytes[1 + type_len + length_len, frame_length])

    refute settings.key?(0x06), "SETTINGS_MAX_FIELD_SECTION_SIZE must not be present when not configured"
  end

  # === Extended CONNECT (RFC 9220) ===

  def test_control_stream_advertises_enable_connect_protocol
    stream = Quicsilver::Protocol.build_control_stream
    bytes = stream.bytes

    _, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
    frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
    settings = parse_settings(bytes[1 + type_len + length_len, frame_length])

    assert_equal 1, settings[0x08], "SETTINGS_ENABLE_CONNECT_PROTOCOL must be 1"
  end

  def test_control_stream_advertises_h3_datagram
    stream = Quicsilver::Protocol.build_control_stream
    bytes = stream.bytes

    _, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
    frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
    settings = parse_settings(bytes[1 + type_len + length_len, frame_length])

    assert_equal 1, settings[0x33], "SETTINGS_H3_DATAGRAM must be 1"
  end

  # === GREASE (RFC 9114) ===

  def test_control_stream_settings_contain_a_grease_id
    stream = Quicsilver::Protocol.build_control_stream
    bytes = stream.bytes

    # Parse past stream type (0x00) to SETTINGS frame
    _, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
    frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
    settings = parse_settings(bytes[1 + type_len + length_len, frame_length])

    grease_settings = settings.keys.select { |id| grease_id?(id) }
    assert grease_settings.size >= 1, "SETTINGS must contain at least one GREASE identifier"
  end

  def test_grease_setting_id_varies_across_calls
    ids = 10.times.map do
      stream = Quicsilver::Protocol.build_control_stream
      bytes = stream.bytes
      _, type_len = Quicsilver::Protocol.decode_varint(bytes, 1)
      frame_length, length_len = Quicsilver::Protocol.decode_varint(bytes, 1 + type_len)
      settings = parse_settings(bytes[1 + type_len + length_len, frame_length])
      settings.keys.find { |id| grease_id?(id) }
    end

    assert ids.uniq.size > 1, "GREASE setting ID should be random, got same value every time"
  end

  # GREASE frames are sent once per connection (in setup_http3_streams and
  # control stream SETTINGS), not per response — matching quiche's behaviour.
  # ResponseEncoder no longer includes GREASE frames.
  def test_response_does_not_include_grease_frame
    encoder = Quicsilver::Protocol::ResponseEncoder.new(200, { "content-type" => "text/plain" }, ["hello"])
    data = encoder.encode

    frames = parse_frames(data)
    grease_frames = frames.select { |f| grease_id?(f[:type]) }
    assert_equal 0, grease_frames.size, "Response should not contain GREASE frames (sent at connection level)"
  end

  def test_response_starts_with_headers_frame
    encoder = Quicsilver::Protocol::ResponseEncoder.new(200, {}, ["body"])
    data = encoder.encode

    frames = parse_frames(data)
    assert frames.size >= 1, "Expected at least one frame"
    assert_equal Quicsilver::Protocol::FRAME_HEADERS, frames.first[:type], "First frame must be HEADERS"
  end

  private

  # RFC 9114 §7.2.4.1: GREASE IDs follow the formula 0x1f * N + 0x21
  def grease_id?(id)
    id >= 33 && (id - 33) % 31 == 0
  end

  def parse_frames(data)
    frames = []
    offset = 0
    bytes = data.bytes
    while offset < bytes.size
      type, type_len = Quicsilver::Protocol.decode_varint(bytes, offset)
      break if type_len == 0
      length, length_len = Quicsilver::Protocol.decode_varint(bytes, offset + type_len)
      break if length_len == 0
      payload = data.byteslice(offset + type_len + length_len, length)
      frames << { type: type, length: length, payload: payload }
      offset += type_len + length_len + length
    end
    frames
  end

  def parse_settings(bytes)
    settings = {}
    offset = 0
    while offset < bytes.size
      id, id_len = Quicsilver::Protocol.decode_varint(bytes, offset)
      value, value_len = Quicsilver::Protocol.decode_varint(bytes, offset + id_len)
      settings[id] = value
      offset += id_len + value_len
    end
    settings
  end

  public

  def test_decode_varint_insufficient_bytes
    # First byte indicates 2-byte varint but only 1 byte available
    bytes = [0x40]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 0, value
    assert_equal 0, length
  end

  def test_decode_varint_empty_array
    bytes = []
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 0, value
    assert_equal 0, length
  end

  def test_decode_varint_offset_out_of_bounds
    bytes = [0x25]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 5)
    assert_equal 0, value
    assert_equal 0, length
  end

  def test_decode_varint_insufficient_bytes_four_byte
    # First byte indicates 4-byte varint but only 2 bytes available
    bytes = [0x80, 0x00]
    value, length = Quicsilver::Protocol.decode_varint(bytes, 0)
    assert_equal 0, value
    assert_equal 0, length
  end
end
