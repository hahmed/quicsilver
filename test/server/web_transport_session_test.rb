# frozen_string_literal: true

require "test_helper"

class WebTransportSessionTest < Minitest::Test
  def test_session_exposes_request_context
    session = build_session(
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "example.com:3000",
        ":path" => "/cable", "origin" => "https://example.com"
      }
    )

    assert_equal "/cable", session.path
    assert_equal "example.com:3000", session.authority
    assert_equal "https://example.com", session.headers["origin"]
  end

  def test_session_not_open_before_accept
    session = build_session
    refute session.open?
  end

  def test_on_datagram_receives_data
    session = build_session
    received = nil
    session.on_datagram { |data| received = data }
    session.receive_datagram("hello")

    assert_equal "hello", received
  end

  def test_on_close_fires_on_fire_close
    session = build_session
    closed = false
    session.on_close { closed = true }
    session.notify_close

    assert closed
    refute session.open?
  end

  def test_headers_exclude_pseudo_headers
    session = build_session(
      headers: {
        ":method" => "CONNECT", ":protocol" => "webtransport",
        ":scheme" => "https", ":authority" => "x", ":path" => "/ws",
        "sec-webtransport-http3-draft" => "draft02", "origin" => "https://x"
      }
    )

    assert_equal "CONNECT", session.headers[":method"]
    assert_equal "webtransport", session.headers[":protocol"]
    assert_equal "draft02", session.headers["sec-webtransport-http3-draft"]
  end

  private

  def build_session(headers: nil)
    headers ||= {
      ":method" => "CONNECT", ":protocol" => "webtransport",
      ":scheme" => "https", ":authority" => "localhost:4433", ":path" => "/cable"
    }
    connection = Minitest::Mock.new
    stream = Minitest::Mock.new
    stream.expect(:stream_id, 4)
    stream.expect(:stream_handle, 99999)

    Quicsilver::Server::WebTransportSession.new(
      connection: connection,
      stream: stream,
      headers: headers
    )
  end
end
