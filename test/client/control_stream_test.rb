# frozen_string_literal: true

require "test_helper"

# Tests for client-side processing of the server's control stream.
# RFC 9114 §7.2.4: Client MUST process server's SETTINGS.
# RFC 9114 §5.2: Client MUST NOT send new requests after receiving GOAWAY.
class ClientControlStreamTest < Minitest::Test
  parallelize_me!

  def setup
    @client = Quicsilver::Client.new("localhost", 4433)
  end

  # === Server SETTINGS processing (RFC 9114 §7.2.4) ===

  def test_client_stores_peer_settings
    send_server_control_stream(settings: { 0x01 => 0, 0x07 => 0 })

    assert_equal 0, @client.peer_settings[0x01]
    assert_equal 0, @client.peer_settings[0x07]
  end

  def test_client_stores_max_field_section_size
    send_server_control_stream(settings: { 0x06 => 4096 })

    assert_equal 4096, @client.peer_max_field_section_size
  end

  def test_client_peer_settings_empty_before_control_stream
    assert_equal({}, @client.peer_settings)
    assert_nil @client.peer_max_field_section_size
  end

  # === Server GOAWAY processing (RFC 9114 §5.2) ===

  def test_client_tracks_peer_goaway_id
    send_server_control_stream(goaway_id: 8)

    assert_equal 8, @client.peer_goaway_id
  end

  def test_client_draining_after_goaway
    refute @client.draining?

    send_server_control_stream(goaway_id: 8)

    assert @client.draining?
  end

  def test_client_goaway_id_must_not_increase
    send_server_control_stream(goaway_id: 8)

    assert_raises(Quicsilver::Protocol::FrameError) do
      send_goaway_on_control_stream(12)
    end

    assert_equal 8, @client.peer_goaway_id, "Should not update after rejected increase"
  end

  def test_client_goaway_id_can_decrease
    send_server_control_stream(goaway_id: 12)
    send_goaway_on_control_stream(4)

    assert_equal 4, @client.peer_goaway_id
  end

  # === GOAWAY blocks new requests ===

  def test_build_request_raises_when_draining
    # Simulate: client is connected and receives GOAWAY
    @client.instance_variable_set(:@connected, true)
    @client.instance_variable_set(:@connection_data, [1, 2])
    send_server_control_stream(goaway_id: 0)

    assert_raises(Quicsilver::GoAwayError) do
      @client.build_request("GET", "/test")
    end
  end

  # === GOAWAY fails in-flight requests (RFC 9114 §5.2) ===

  # RFC 9114 §5.2: "requests with a stream ID greater than or equal to
  # the identifier contained in the GOAWAY frame... will not be processed"
  def test_goaway_fails_requests_at_and_above_goaway_id
    setup_connected_client
    req_4 = add_pending_request(stream_id: 4)
    req_8 = add_pending_request(stream_id: 8)
    req_12 = add_pending_request(stream_id: 12)

    send_server_control_stream(goaway_id: 8)

    assert_raises(Quicsilver::Client::Request::ResetError) { req_8.response(timeout: 0.1) }
    assert_raises(Quicsilver::Client::Request::ResetError) { req_12.response(timeout: 0.1) }
    assert req_4.pending?, "Request on stream 4 should still be pending"
  end

  def test_goaway_with_zero_fails_all
    setup_connected_client
    req_0 = add_pending_request(stream_id: 0)
    req_4 = add_pending_request(stream_id: 4)

    send_server_control_stream(goaway_id: 0)

    assert_raises(Quicsilver::Client::Request::ResetError) { req_0.response(timeout: 0.1) }
    assert_raises(Quicsilver::Client::Request::ResetError) { req_4.response(timeout: 0.1) }
  end

  def test_goaway_decrease_fails_newly_affected_requests
    setup_connected_client
    req_0 = add_pending_request(stream_id: 0)
    req_4 = add_pending_request(stream_id: 4)
    req_8 = add_pending_request(stream_id: 8)
    req_12 = add_pending_request(stream_id: 12)

    # First GOAWAY at 12: fails stream 12, leaves 0/4/8 pending
    send_server_control_stream(goaway_id: 12)
    assert_raises(Quicsilver::Client::Request::ResetError) { req_12.response(timeout: 0.1) }
    assert req_8.pending?
    assert req_4.pending?

    # Second GOAWAY at 4 (decrease): fails streams 4 and 8, leaves 0 pending
    send_goaway_on_control_stream(4)
    assert_raises(Quicsilver::Client::Request::ResetError) { req_4.response(timeout: 0.1) }
    assert_raises(Quicsilver::Client::Request::ResetError) { req_8.response(timeout: 0.1) }
    assert req_0.pending?, "Request below new GOAWAY should still be pending"
  end

  # === SETTINGS_MAX_FIELD_SECTION_SIZE enforcement (RFC 9114 §4.2.2) ===

  def test_enforces_max_field_section_size_on_request
    setup_connected_client
    send_server_control_stream(settings: { 0x06 => 64 })

    mock_stream = Quicsilver::Transport::Stream.new(99999)
    @client.stub(:open_stream, mock_stream) do
      assert_raises(Quicsilver::Error) do
        @client.build_request("GET", "/test", headers: { "x-big" => "a" * 100 })
      end
    end
  end

  def test_allows_request_within_max_field_section_size
    setup_connected_client
    send_server_control_stream(settings: { 0x06 => 4096 })

    mock_stream = Quicsilver::Transport::Stream.new(99999)
    sent = false
    mock_stream.define_singleton_method(:send) { |data, fin: false| sent = true; true }

    @client.stub(:open_stream, mock_stream) do
      @client.build_request("GET", "/short")
    end
    assert sent
  end

  def test_no_enforcement_when_setting_not_received
    setup_connected_client
    mock_stream = Quicsilver::Transport::Stream.new(99999)
    sent = false
    mock_stream.define_singleton_method(:send) { |data, fin: false| sent = true; true }

    @client.stub(:open_stream, mock_stream) do
      @client.build_request("GET", "/test", headers: { "x-big" => "a" * 10_000 })
    end
    assert sent
  end

  # === SETTINGS validation ===

  def test_client_rejects_http2_setting_ids
    assert_raises(Quicsilver::Protocol::FrameError) do
      send_server_control_stream(settings: { 0x02 => 1 })
    end
  end

  def test_client_rejects_duplicate_settings_frame
    # First SETTINGS is fine, second on the same control stream is an error
    send_server_control_stream(settings: { 0x01 => 0 })

    assert_raises(Quicsilver::Protocol::FrameError) do
      send_settings_on_control_stream({ 0x01 => 0 })
    end
  end

  private

  # Server-initiated unidirectional stream ID (0x03 = server-initiated uni)
  SERVER_UNI_STREAM_BASE = 3

  def send_server_control_stream(settings: { 0x01 => 0 }, goaway_id: nil)
    stream_id = SERVER_UNI_STREAM_BASE
    data = build_control_stream_data(settings, goaway_id: goaway_id)

    @client.receive_control_data(stream_id, data)
  end

  def send_goaway_on_control_stream(goaway_id)
    stream_id = SERVER_UNI_STREAM_BASE
    @client.receive_control_data(stream_id, build_goaway_frame(goaway_id))
  end

  def send_settings_on_control_stream(settings)
    stream_id = SERVER_UNI_STREAM_BASE
    @client.receive_control_data(stream_id, build_settings_frame(settings))
  end

  def build_control_stream_data(settings, goaway_id: nil)
    data = "".b
    data << [0x00].pack("C")  # Control stream type
    data << build_settings_frame(settings)
    data << build_goaway_frame(goaway_id) if goaway_id
    data
  end

  def build_settings_frame(settings)
    payload = "".b
    settings.each do |id, value|
      payload << Quicsilver::Protocol.encode_varint(id)
      payload << Quicsilver::Protocol.encode_varint(value)
    end
    Quicsilver::Protocol.encode_varint(Quicsilver::Protocol::FRAME_SETTINGS) +
      Quicsilver::Protocol.encode_varint(payload.bytesize) +
      payload
  end

  def build_goaway_frame(stream_id)
    Quicsilver::Protocol.build_goaway_frame(stream_id)
  end

  def setup_connected_client
    @client.instance_variable_set(:@connected, true)
    @client.instance_variable_set(:@connection_data, [1, 2])
  end

  def add_pending_request(stream_id:)
    handle = stream_id + 1000
    mock_stream = Quicsilver::Transport::Stream.new(handle)
    request = Quicsilver::Client::Request.new(@client, mock_stream)
    @client.instance_variable_get(:@inflight)[handle] = { request: request, stream_id: stream_id }
    request
  end
end
