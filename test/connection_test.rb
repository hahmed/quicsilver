# frozen_string_literal: true

require "test_helper"

class ConnectionTest < Minitest::Test
  def setup
    @connection = Quicsilver::Connection.new(12345, [12345, 67890])
  end

  # === Binary encoding ===

  def test_buffer_data_handles_invalid_utf8
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

  # === Control stream validation (#7, #8, #9) ===

  def test_complete_stream_returns_binary_encoding
    result = @connection.complete_stream(999, nil)
    assert_equal Encoding::ASCII_8BIT, result.encoding
  end

  def test_rejects_reserved_settings_header_table_size
    conn = Quicsilver::Connection.new(12345, [12345, 67890])
    settings_payload = encode_varint(0x00) + encode_varint(0)
    control_payload = encode_varint(Quicsilver::HTTP3::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    assert_raises(Quicsilver::HTTP3::FrameError) do
      conn.set_control_stream(1, control_payload)
    end
  end

  def test_accepts_enable_connect_protocol
    settings_payload = encode_varint(0x08) + encode_varint(1)
    control_payload = encode_varint(Quicsilver::HTTP3::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    @connection.set_control_stream(1, control_payload)
    assert_equal 1, @connection.settings[0x08]
  end

  def test_rejects_http2_settings_identifiers
    # RFC 9114 §7.2.4.1 / §11.2.2: identifiers 0x00, 0x02, 0x03, 0x04, 0x05 are reserved
    [0x00, 0x02, 0x03, 0x04, 0x05].each do |id|
      conn = Quicsilver::Connection.new(12345, [12345, 67890])
      settings_payload = encode_varint(id) + encode_varint(0)
      control_payload = encode_varint(Quicsilver::HTTP3::FRAME_SETTINGS) +
                        encode_varint(settings_payload.bytesize) +
                        settings_payload

      error = assert_raises(Quicsilver::HTTP3::FrameError, "Should reject HTTP/2 setting 0x#{id.to_s(16)}") do
        conn.set_control_stream(1, control_payload)
      end
      assert_match(/0x#{id.to_s(16)}/i, error.message)
    end
  end

  def test_accepts_valid_h3_settings
    settings_payload = encode_varint(0x01) + encode_varint(0) +  # QPACK_MAX_TABLE_CAPACITY
                       encode_varint(0x07) + encode_varint(0)    # QPACK_BLOCKED_STREAMS
    control_payload = encode_varint(Quicsilver::HTTP3::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    @connection.set_control_stream(1, control_payload)

    assert_equal 0, @connection.settings[0x01]
    assert_equal 0, @connection.settings[0x07]
  end

  def test_rejects_duplicate_control_stream
    @connection.set_control_stream(1, build_settings_frame)

    assert_raises(Quicsilver::HTTP3::FrameError) do
      @connection.set_control_stream(2, build_settings_frame)
    end
  end

  def test_rejects_duplicate_qpack_encoder_stream
    stream1 = build_unidirectional_stream(0x02)
    stream2 = build_unidirectional_stream(0x02)

    @connection.handle_unidirectional_stream(stream1)

    assert_raises(Quicsilver::HTTP3::FrameError) do
      @connection.handle_unidirectional_stream(stream2)
    end
  end

  def test_rejects_duplicate_qpack_decoder_stream
    stream1 = build_unidirectional_stream(0x03)
    stream2 = build_unidirectional_stream(0x03)

    @connection.handle_unidirectional_stream(stream1)

    assert_raises(Quicsilver::HTTP3::FrameError) do
      @connection.handle_unidirectional_stream(stream2)
    end
  end

  def test_settings_must_be_first_frame_on_control_stream
    # Send a DATA frame before SETTINGS on the control stream
    data_frame = encode_varint(Quicsilver::HTTP3::FRAME_DATA) +
                 encode_varint(4) + "test"

    assert_raises(Quicsilver::HTTP3::FrameError) do
      @connection.set_control_stream(1, data_frame)
    end
  end

  # === GOAWAY stream ID (#11) ===

  def test_parse_settings_truncated_value_not_stored
    # Setting ID=1 (valid 1-byte varint) + truncated value (0x80 prefix needs 4 bytes)
    settings_payload = "\x01\x80".b
    control_payload = encode_varint(Quicsilver::HTTP3::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    conn = Quicsilver::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, control_payload)

    assert_empty conn.settings
  end

  def test_last_client_stream_id_tracks_bidi_streams
    @connection.track_client_stream(4)
    @connection.track_client_stream(8)
    @connection.track_client_stream(12)

    assert_equal 12, @connection.send(:last_client_stream_id)
  end

  def test_last_client_stream_id_returns_zero_when_no_streams
    assert_equal 0, @connection.send(:last_client_stream_id)
  end

  private

  def encode_varint(value)
    Quicsilver::HTTP3.encode_varint(value)
  end

  def build_settings_frame
    settings_payload = encode_varint(0x01) + encode_varint(0)
    encode_varint(Quicsilver::HTTP3::FRAME_SETTINGS) +
      encode_varint(settings_payload.bytesize) +
      settings_payload
  end

  def build_unidirectional_stream(type)
    stream = Quicsilver::QuicStream.new(3, is_unidirectional: true) # odd stream_id = uni
    stream.append_data([type].pack("C"))
    stream
  end
end
