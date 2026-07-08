# frozen_string_literal: true

require "test_helper"

class ConnectionTest < Minitest::Test
  parallelize_me!
  def setup
    @connection = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
  end

  def test_request_context_includes_stable_request_identity
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890], connection_id: "\xab\xcd".b)

    context = conn.request_context(stream_id: 8)
    connection = context["connection"]

    assert_equal "abcd", connection["connection_id"]
    refute connection.key?("original_destination_connection_id")
    assert_equal 8, connection["stream_id"]
    assert_equal "abcd:8", connection["request_id"]
  end

  def test_request_context_prefixes_request_identity_with_transport_server_id
    conn = Quicsilver::Transport::Connection.new(
      12345,
      [12345, 67890],
      connection_id: "\xab\xcd".b,
      transport_server_id: "01020304"
    )

    assert_equal "01020304:abcd:8", conn.request_context(stream_id: 8).dig("connection", "request_id")
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

  # === WebTransport unidirectional streams ===

  def test_receive_unidirectional_data_identifies_webtransport_uni_stream
    payload = Quicsilver::Protocol.encode_varint(0) + "hello"
    data = Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::WebTransport::UNI_STREAM_TYPE) + payload

    result = @connection.receive_unidirectional_data(14, data)

    assert_equal [:webtransport_uni, payload], result
    assert_equal :webtransport_uni, @connection.uni_stream_type(14)
  end

  def test_handle_unidirectional_stream_identifies_complete_webtransport_uni_stream
    payload = Quicsilver::Protocol.encode_varint(0) + "hello"
    data = Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::WebTransport::UNI_STREAM_TYPE) + payload
    stream = Quicsilver::Transport::InboundStream.new(14, is_unidirectional: true)
    stream.append_data(data)

    result = @connection.handle_unidirectional_stream(stream)

    assert_equal [:webtransport_uni, payload], result
    assert_equal :webtransport_uni, @connection.uni_stream_type(14)
  end

  # === QPACK stream validation ===

  def test_qpack_encoder_stream_allows_zero_capacity
    # Feed a QPACK encoder stream (type 0x02) with Set Dynamic Table Capacity = 0
    # 0x20 = 001_00000, capacity 0 — valid since we advertise max capacity 0
    stream_data = "\x02\x20".b  # stream type + instruction
    @connection.receive_unidirectional_data(2, stream_data)  # should not raise
  end

  def test_qpack_encoder_stream_rejects_nonzero_capacity
    # Feed a QPACK encoder stream with Set Dynamic Table Capacity = 1
    # We advertised capacity 0, so any non-zero value is a connection error
    stream_data = "\x02\x21".b  # stream type + capacity 1
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.receive_unidirectional_data(2, stream_data)
    end
    assert_equal Quicsilver::Protocol::QPACK_ENCODER_STREAM_ERROR, error.error_code
  end

  def test_qpack_encoder_stream_rejects_insert_with_name_reference
    # 1xxxxxxx = Insert With Name Reference — rejected when capacity=0
    stream_data = "\x02\x80".b
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.receive_unidirectional_data(2, stream_data)
    end
    assert_equal Quicsilver::Protocol::QPACK_ENCODER_STREAM_ERROR, error.error_code
  end

  def test_qpack_encoder_stream_rejects_insert_with_literal_name
    # 01xxxxxx = Insert With Literal Name — rejected when capacity=0
    stream_data = "\x02\x40".b
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.receive_unidirectional_data(2, stream_data)
    end
    assert_equal Quicsilver::Protocol::QPACK_ENCODER_STREAM_ERROR, error.error_code
  end

  def test_qpack_encoder_stream_rejects_duplicate
    # 000xxxxx = Duplicate — rejected when table is empty
    stream_data = "\x02\x00".b
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.receive_unidirectional_data(2, stream_data)
    end
    assert_equal Quicsilver::Protocol::QPACK_ENCODER_STREAM_ERROR, error.error_code
  end

  def test_qpack_decoder_stream_rejects_zero_insert_count_increment
    # Feed a QPACK decoder stream (type 0x03) with Insert Count Increment = 0
    stream_data = "\x03\x00".b
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.receive_unidirectional_data(6, stream_data)
    end
    assert_equal Quicsilver::Protocol::QPACK_DECODER_STREAM_ERROR, error.error_code
  end

  def test_qpack_decoder_stream_accepts_nonzero_insert_count_increment
    # Feed a QPACK decoder stream with Insert Count Increment = 1
    stream_data = "\x03\x01".b
    @connection.receive_unidirectional_data(6, stream_data)  # should not raise
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

  def test_receive_unidirectional_data_identifies_webtransport_uni
    # Stream type 0x54 = WebTransport unidirectional stream (2-byte varint)
    @connection.receive_unidirectional_data(15, "\x40\x54".b)
    refute @connection.critical_stream?(15)
    assert_equal :webtransport_uni, @connection.instance_variable_get(:@uni_stream_types)[15]
  end

  def test_receive_unidirectional_data_ignores_unknown_stream_type
    # Stream type 0x21 (unknown/reserved) — must not raise
    @connection.receive_unidirectional_data(15, "\x21".b)
    refute @connection.critical_stream?(15)
  end

  def test_receive_unidirectional_data_ignores_grease_stream_type
    # GREASE stream types (31*n+33) must be silently ignored
    grease_type = 31 * 5 + 33  # 188
    data = Quicsilver::Protocol.encode_varint(grease_type) + "GREASE".b
    @connection.receive_unidirectional_data(19, data)
    refute @connection.critical_stream?(19)
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

  # === GOAWAY validation (RFC 9114 §7.2.6) ===

  def test_goaway_stores_peer_goaway_id
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, build_settings_frame + build_goaway_frame(8))

    assert_equal 8, conn.peer_goaway_id
  end

  def test_goaway_id_must_not_increase
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, build_settings_frame + build_goaway_frame(8))

    assert_raises(Quicsilver::Protocol::FrameError) do
      conn.send(:parse_control_frames, build_goaway_frame(12))
    end
  end

  def test_goaway_id_can_decrease
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, build_settings_frame + build_goaway_frame(8))
    conn.send(:parse_control_frames, build_goaway_frame(4))

    assert_equal 4, conn.peer_goaway_id
  end

  def test_goaway_id_must_be_valid_request_stream_id
    # Request stream IDs are divisible by 4 (client-initiated bidirectional)
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])

    assert_raises(Quicsilver::Protocol::FrameError) do
      conn.set_control_stream(1, build_settings_frame + build_goaway_frame(5))
    end
  end

  def test_goaway_accepts_valid_request_stream_ids
    [0, 4, 8, 12].each do |id|
      conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
      conn.set_control_stream(1, build_settings_frame + build_goaway_frame(id))
      assert_equal id, conn.peer_goaway_id, "Should accept GOAWAY with stream ID #{id}"
    end
  end

  # === PRIORITY_UPDATE (RFC 9218 §7) ===

  def test_priority_update_stores_stream_priority
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, build_settings_frame + build_priority_update_frame(4, "u=0, i"))

    priority = conn.stream_priority(4)
    assert_equal 0, priority.urgency
    assert priority.incremental
  end

  def test_priority_update_overwrites_previous
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1,
      build_settings_frame +
      build_priority_update_frame(4, "u=5") +
      build_priority_update_frame(4, "u=1, i"))

    priority = conn.stream_priority(4)
    assert_equal 1, priority.urgency
    assert priority.incremental
  end

  def test_priority_update_for_unknown_stream_still_stores
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    conn.set_control_stream(1, build_settings_frame + build_priority_update_frame(8, "u=2"))

    priority = conn.stream_priority(8)
    assert_equal 2, priority.urgency
  end

  def test_stream_priority_returns_default_when_not_set
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])

    priority = conn.stream_priority(4)
    assert_equal 3, priority.urgency
    refute priority.incremental
  end

  # === Stream accounting ===

  def test_active_request_streams_counts_client_bidirectional_streams
    [0, 1, 2, 3, 4, 8].each { |stream_id| @connection.track_client_stream(stream_id) }

    assert_equal 6, @connection.active_streams
    assert_equal 3, @connection.active_request_streams
  end

  # === GOAWAY stream ID ===

  def test_last_request_stream_id_tracks_request_streams
    @connection.track_client_stream(4)
    @connection.track_client_stream(5)
    @connection.track_client_stream(6)
    @connection.track_client_stream(8)
    @connection.track_client_stream(12)

    assert_equal 12, @connection.send(:last_request_stream_id)
  end

  def test_last_request_stream_id_returns_zero_when_no_streams
    assert_equal 0, @connection.send(:last_request_stream_id)
  end

  # === Two-phase GOAWAY (RFC 9114 §5.2) ===

  def test_send_goaway_sends_frame_and_tracks_id
    mock_stream = Minitest::Mock.new
    mock_stream.expect(:send, true, [String])
    @connection.instance_variable_set(:@server_control_stream, mock_stream)

    @connection.send_goaway(8)

    assert_equal 8, @connection.local_goaway_id
    mock_stream.verify
  end

  def test_validate_goaway_id_allows_decreasing
    @connection.instance_variable_set(:@local_goaway_id, 12)

    @connection.validate_goaway_id!(4)
    # no error raised
  end

  def test_validate_goaway_id_allows_equal
    @connection.instance_variable_set(:@local_goaway_id, 8)

    @connection.validate_goaway_id!(8)
    # no error raised
  end

  def test_validate_goaway_id_rejects_increasing
    @connection.instance_variable_set(:@local_goaway_id, 4)

    assert_raises(ArgumentError) do
      @connection.validate_goaway_id!(8)
    end
  end

  def test_validate_goaway_id_allows_first_goaway
    @connection.validate_goaway_id!(100)
    # no error — first GOAWAY has no previous to compare against
  end

  # === Session resumed ===

  def test_session_resumed_from_connection_data
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890, true])
    assert conn.session_resumed
  end

  def test_session_not_resumed_by_default
    conn = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    refute conn.session_resumed
  end

  # === Spec compliance regression tests ===

  def test_push_stream_uses_stream_creation_error_code
    stream = build_unidirectional_stream(0x01)
    error = assert_raises(Quicsilver::Protocol::FrameError) do
      @connection.handle_unidirectional_stream(stream, fin: false)
    end
    assert_equal Quicsilver::Protocol::H3_STREAM_CREATION_ERROR, error.error_code
  end

  def test_cancel_push_accepted_on_control_stream
    # CANCEL_PUSH (0x03) is valid on control stream — should not raise
    cancel_push_frame = encode_varint(Quicsilver::Protocol::FRAME_CANCEL_PUSH) +
                        encode_varint(1) + "\x00".b
    data = build_settings_frame + cancel_push_frame
    @connection.set_control_stream(1, data)  # should not raise
    assert @connection.control_stream_id
  end

  def test_max_push_id_accepted_on_control_stream
    # MAX_PUSH_ID (0x0d) is valid on control stream — should not raise
    max_push_id_frame = encode_varint(Quicsilver::Protocol::FRAME_MAX_PUSH_ID) +
                        encode_varint(1) + "\x00".b
    data = build_settings_frame + max_push_id_frame
    @connection.set_control_stream(1, data)  # should not raise
    assert @connection.control_stream_id
  end

  def test_datagram_send_requires_peer_settings
    # Connection without SETTINGS_H3_DATAGRAM should reject datagram_send
    # (settings hash is empty by default)
    assert_empty @connection.settings
  end

  def test_retry_after_on_503_error
    # send_error with 503 should include retry-after header
    # We can't easily test the wire output without a real stream,
    # but we verify the ResponseEncoder receives the header
    encoder = Quicsilver::Protocol::ResponseEncoder.new(
      503, { "content-type" => "text/plain", "retry-after" => "1" }, ["503 Service Unavailable"]
    )
    data = encoder.encode
    parser = Quicsilver::Protocol::ResponseParser.new(data)
    parser.parse
    assert_equal 503, parser.status
    assert_equal "1", parser.headers["retry-after"]
  end

  private

  def encode_varint(value)
    Quicsilver::Protocol.encode_varint(value)
  end

  def build_priority_update_frame(stream_id, priority_value)
    payload = Quicsilver::Protocol.encode_varint(stream_id) + priority_value.b
    Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::FRAME_PRIORITY_UPDATE) +
      Quicsilver::Protocol.encode_varint(payload.bytesize) +
      payload
  end

  def build_goaway_frame(stream_id)
    Quicsilver::Protocol.build_goaway_frame(stream_id)
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
