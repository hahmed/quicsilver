# frozen_string_literal: true

require "test_helper"

class ConnectionTest < Minitest::Test
  def setup
    @connection = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
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
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    settings_payload = encode_varint(0x00) + encode_varint(0)
    control_payload = encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    assert_raises(Quicsilver::Protocol::FrameError) do
      conn.set_control_stream(1, control_payload)
    end
  end

  def test_accepts_enable_connect_protocol
    settings_payload = encode_varint(0x08) + encode_varint(1)
    control_payload = encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    @connection.set_control_stream(1, control_payload)
    assert_equal 1, @connection.settings[0x08]
  end

  def test_rejects_http2_settings_identifiers
    # RFC 9114 §7.2.4.1 / §11.2.2: identifiers 0x00, 0x02, 0x03, 0x04, 0x05 are reserved
    [0x00, 0x02, 0x03, 0x04, 0x05].each do |id|
      conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
      settings_payload = encode_varint(id) + encode_varint(0)
      control_payload = encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
                        encode_varint(settings_payload.bytesize) +
                        settings_payload

      error = assert_raises(Quicsilver::Protocol::FrameError, "Should reject HTTP/2 setting 0x#{id.to_s(16)}") do
        conn.set_control_stream(1, control_payload)
      end
      assert_match(/0x#{id.to_s(16)}/i, error.message)
    end
  end

  def test_accepts_valid_h3_settings
    settings_payload = encode_varint(0x01) + encode_varint(0) +  # QPACK_MAX_TABLE_CAPACITY
                       encode_varint(0x07) + encode_varint(0)    # QPACK_BLOCKED_STREAMS
    control_payload = encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    @connection.set_control_stream(1, control_payload)

    assert_equal 0, @connection.settings[0x01]
    assert_equal 0, @connection.settings[0x07]
  end

  def test_rejects_duplicate_settings_frame
    @connection.set_control_stream(1, build_settings_frame)

    # Second SETTINGS on same control stream is a protocol error
    second_settings = build_settings_frame
    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.send(:parse_control_frames, second_settings)
    end
  end

  def test_rejects_push_stream_from_client
    stream = build_unidirectional_stream(0x01)

    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.handle_unidirectional_stream(stream, fin: false)
    end
  end

  def test_rejects_duplicate_control_stream
    @connection.set_control_stream(1, build_settings_frame)

    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.set_control_stream(2, build_settings_frame)
    end
  end

  def test_rejects_duplicate_qpack_encoder_stream
    stream1 = build_unidirectional_stream(0x02)
    stream2 = build_unidirectional_stream(0x02)

    @connection.handle_unidirectional_stream(stream1, fin: false)

    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.handle_unidirectional_stream(stream2, fin: false)
    end
  end

  def test_rejects_duplicate_qpack_decoder_stream
    stream1 = build_unidirectional_stream(0x03)
    stream2 = build_unidirectional_stream(0x03)

    @connection.handle_unidirectional_stream(stream1, fin: false)

    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.handle_unidirectional_stream(stream2, fin: false)
    end
  end

  def test_settings_must_be_first_frame_on_control_stream
    # Send a DATA frame before SETTINGS on the control stream
    data_frame = encode_varint(Quicsilver::Protocol::FRAME_DATA) +
                 encode_varint(4) + "test"

    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.set_control_stream(1, data_frame)
    end
  end

  # === GOAWAY stream ID (#11) ===

  def test_parse_settings_truncated_value_not_stored
    # Setting ID=1 (valid 1-byte varint) + truncated value (0x80 prefix needs 4 bytes)
    settings_payload = "\x01\x80".b
    control_payload = encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, control_payload)

    assert_empty conn.settings
  end

  # === Duplicate settings identifiers ===

  def test_rejects_duplicate_settings_identifiers
    settings_payload = encode_varint(0x01) + encode_varint(0) +
                       encode_varint(0x01) + encode_varint(1)
    control_payload = encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
                      encode_varint(settings_payload.bytesize) +
                      settings_payload

    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    assert_raises(Quicsilver::Protocol::FrameError) do
      conn.set_control_stream(1, control_payload)
    end
  end

  # === Stream type varint decoding ===

  def test_stream_type_decoded_as_varint
    # Control stream type 0x00 encoded as 2-byte varint: \x40\x00
    stream = Quicsilver::Transport::InboundStream.new(3, is_unidirectional: true)
    stream.append_data("\x40\x00".b + build_settings_frame)

    @connection.handle_unidirectional_stream(stream, fin: false)
    assert_equal 3, @connection.control_stream_id
  end

  # === HTTP/2 reserved frame types on control stream ===

  def test_rejects_data_frame_on_control_stream
    data_after_settings = build_settings_frame +
                          encode_varint(Quicsilver::Protocol::FRAME_DATA) +
                          encode_varint(4) + "test"

    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    assert_raises(Quicsilver::Protocol::FrameError) do
      conn.set_control_stream(1, data_after_settings)
    end
  end

  def test_rejects_headers_frame_on_control_stream
    data_after_settings = build_settings_frame +
                          encode_varint(Quicsilver::Protocol::FRAME_HEADERS) +
                          encode_varint(4) + "test"

    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    assert_raises(Quicsilver::Protocol::FrameError) do
      conn.set_control_stream(1, data_after_settings)
    end
  end

  def test_rejects_http2_reserved_frame_types_on_control_stream
    [0x02, 0x06, 0x08, 0x09].each do |type|
      data_after_settings = build_settings_frame +
                            encode_varint(type) +
                            encode_varint(0)

      conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
      assert_raises(Quicsilver::Protocol::FrameError, "Should reject frame type 0x#{type.to_s(16)}") do
        conn.set_control_stream(1, data_after_settings)
      end
    end
  end

  # === Critical stream detection ===

  def test_critical_stream_identifies_control_stream
    @connection.set_control_stream(3, build_settings_frame)
    assert @connection.critical_stream?(3)
    refute @connection.critical_stream?(99)
  end

  def test_critical_stream_identifies_qpack_streams
    stream_enc = build_unidirectional_stream(0x02)
    stream_dec = build_unidirectional_stream(0x03)

    @connection.handle_unidirectional_stream(stream_enc, fin: false)
    @connection.handle_unidirectional_stream(stream_dec, fin: false)

    assert @connection.critical_stream?(3)  # both use stream_id 3 from helper, but let's check properly
  end

  # === FIN on critical streams ===

  def test_fin_on_control_stream_raises_closed_critical_stream
    stream = Quicsilver::Transport::InboundStream.new(3, is_unidirectional: true)
    stream.append_data("\x00".b + build_settings_frame)

    # First open it without FIN
    @connection.handle_unidirectional_stream(stream, fin: false)

    # Then FIN on a known critical stream
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.handle_unidirectional_stream(stream, fin: true)
    end
    assert_equal Quicsilver::Protocol::H3_CLOSED_CRITICAL_STREAM, error.error_code
  end

  def test_fin_on_new_control_stream_raises_closed_critical_stream
    stream = Quicsilver::Transport::InboundStream.new(3, is_unidirectional: true)
    stream.append_data("\x00".b + build_settings_frame)

    # Stream identified and immediately closed with FIN
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.handle_unidirectional_stream(stream, fin: true)
    end
    assert_equal Quicsilver::Protocol::H3_CLOSED_CRITICAL_STREAM, error.error_code
  end

  def test_no_fin_on_control_stream_does_not_raise
    stream = Quicsilver::Transport::InboundStream.new(3, is_unidirectional: true)
    stream.append_data("\x00".b + build_settings_frame)

    @connection.handle_unidirectional_stream(stream, fin: false)
    assert_equal 3, @connection.control_stream_id
  end

  # === QPACK stream validation ===

  def test_validate_qpack_encoder_rejects_dynamic_table_capacity
    # 001xxxxx = Set Dynamic Table Capacity instruction
    data = "\x20".b  # 0x20 = 001_00000, capacity 0 (but any instruction is invalid for us)

    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.send(:validate_qpack_encoder_data, data)
    end
    assert_equal Quicsilver::Protocol::QPACK_ENCODER_STREAM_ERROR, error.error_code
  end

  def test_validate_qpack_encoder_ignores_non_capacity_instructions
    # 1xxxxxxx = Insert With Name Reference (not a capacity instruction)
    data = "\x80".b
    @connection.send(:validate_qpack_encoder_data, data)  # should not raise
  end

  def test_validate_qpack_decoder_rejects_zero_insert_count_increment
    # 00xxxxxx = Insert Count Increment, value 0
    data = "\x00".b

    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.send(:validate_qpack_decoder_data, data)
    end
    assert_equal Quicsilver::Protocol::QPACK_DECODER_STREAM_ERROR, error.error_code
  end

  def test_validate_qpack_decoder_accepts_nonzero_insert_count_increment
    # 00_000001 = Insert Count Increment with value 1
    data = "\x01".b
    @connection.send(:validate_qpack_decoder_data, data)  # should not raise
  end

  # === Incremental unidirectional stream processing ===

  def test_receive_unidirectional_data_identifies_control_stream
    # Stream type 0x00 (control) + SETTINGS frame
    data = "\x00".b + build_settings_frame
    @connection.receive_unidirectional_data(3, data)

    assert_equal 3, @connection.control_stream_id
    assert @connection.critical_stream?(3)
  end

  def test_receive_unidirectional_data_identifies_qpack_encoder
    @connection.receive_unidirectional_data(7, "\x02".b)
    assert @connection.critical_stream?(7)
  end

  def test_receive_unidirectional_data_identifies_qpack_decoder
    @connection.receive_unidirectional_data(11, "\x03".b)
    assert @connection.critical_stream?(11)
  end

  def test_receive_unidirectional_data_ignores_unknown_stream_type
    # Stream type 0x21 (unknown/reserved) — must not raise
    @connection.receive_unidirectional_data(15, "\x21".b)
    refute @connection.critical_stream?(15)
  end

  def test_receive_unidirectional_data_handles_incremental_chunks
    # Send stream type in first chunk, settings in second
    @connection.receive_unidirectional_data(3, "\x00".b)
    assert_equal 3, @connection.control_stream_id

    @connection.receive_unidirectional_data(3, build_settings_frame)
    refute_empty @connection.settings
  end

  def test_receive_unidirectional_data_rejects_duplicate_control_stream
    @connection.receive_unidirectional_data(3, "\x00".b + build_settings_frame)

    assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.receive_unidirectional_data(7, "\x00".b + build_settings_frame)
    end
  end

  # === GOAWAY stream ID ===

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
    Quicsilver::Protocol.encode_varint(value)
  end

  def build_settings_frame
    settings_payload = encode_varint(0x01) + encode_varint(0)
    encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
      encode_varint(settings_payload.bytesize) +
      settings_payload
  end

  def build_unidirectional_stream(type)
    stream = Quicsilver::Transport::InboundStream.new(3, is_unidirectional: true) # odd stream_id = uni
    stream.append_data([type].pack("C"))
    stream
  end
end
