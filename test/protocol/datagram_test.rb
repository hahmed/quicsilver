# frozen_string_literal: true

require "test_helper"

class ProtocolDatagramTest < Minitest::Test
  include HTTP3TestHelpers
  REQUEST_STREAM_ID = 8
  PAYLOAD = "hello"

  def test_encode_prefixes_payload_with_quarter_stream_id
    assert_equal h3_datagram_for(REQUEST_STREAM_ID, PAYLOAD),
      Quicsilver::Protocol::Datagram.encode(REQUEST_STREAM_ID, PAYLOAD)
  end

  def test_encode_accepts_empty_payload
    assert_equal h3_datagram_for(REQUEST_STREAM_ID, ""),
      Quicsilver::Protocol::Datagram.encode(REQUEST_STREAM_ID, "")
  end

  def test_decode_returns_stream_id_and_payload
    stream_id, payload = Quicsilver::Protocol::Datagram.decode(h3_datagram_for(REQUEST_STREAM_ID, PAYLOAD))

    assert_equal REQUEST_STREAM_ID, stream_id
    assert_equal PAYLOAD, payload
  end

  def test_decode_accepts_empty_payload
    stream_id, payload = Quicsilver::Protocol::Datagram.decode(h3_datagram_for(REQUEST_STREAM_ID, ""))

    assert_equal REQUEST_STREAM_ID, stream_id
    assert_equal "".b, payload
  end

  def test_decode_returns_nil_for_incomplete_quarter_stream_id
    assert_nil Quicsilver::Protocol::Datagram.decode(truncated_two_byte_varint)
  end

  def test_quarter_stream_id_returns_http3_datagram_stream_identifier
    assert_equal quarter_stream_id_for(REQUEST_STREAM_ID),
      Quicsilver::Protocol::Datagram.quarter_stream_id(REQUEST_STREAM_ID)
  end

  def test_stream_id_restores_request_stream_id_from_quarter_stream_id
    assert_equal REQUEST_STREAM_ID,
      Quicsilver::Protocol::Datagram.stream_id(quarter_stream_id_for(REQUEST_STREAM_ID))
  end

  private

  def h3_datagram_for(stream_id, payload)
    Quicsilver::Protocol.encode_varint(quarter_stream_id_for(stream_id)) + payload
  end

  def quarter_stream_id_for(stream_id)
    stream_id / Quicsilver::Protocol::Datagram::STREAM_ID_DIVISOR
  end

end
