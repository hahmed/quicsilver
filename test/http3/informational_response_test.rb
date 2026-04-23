# frozen_string_literal: true

require "test_helper"

# Tests for HTTP/3 informational (1xx) responses.
# RFC 9114 §4.1: An HTTP response begins with one or more "informational" (1xx)
# response header sections, each encoded as a single HEADERS frame.
class InformationalResponseTest < Minitest::Test
  parallelize_me!

  # === Encoding ===

  def test_encode_103_early_hints
    data = encode_informational(103, { "link" => '</style.css>; rel=preload' })
    frames = parse_frames(data)

    assert_equal 1, frames.count { |f| f[:type] == 0x01 }, "Should have exactly one HEADERS frame"
    assert_equal 0, frames.count { |f| f[:type] == 0x00 }, "Should have no DATA frames"

    parser = Quicsilver::Protocol::ResponseParser.new(data)
    parser.parse
    assert_equal 103, parser.status
    assert_equal '</style.css>; rel=preload', parser.headers["link"]
  end

  def test_encode_100_continue
    data = encode_informational(100, {})
    parser = Quicsilver::Protocol::ResponseParser.new(data)
    parser.parse
    assert_equal 100, parser.status
  end

  # === 103 followed by 200 (the full flow) ===

  def test_103_then_200_produces_valid_frame_sequence
    informational = encode_informational(103, { "link" => '</style.css>; rel=preload' })
    final = encode_final(200, { "content-type" => "text/html" }, ["<h1>Hello</h1>"])

    combined = informational + final
    frames = parse_frames(combined)

    headers_frames = frames.select { |f| f[:type] == 0x01 }
    data_frames = frames.select { |f| f[:type] == 0x00 }

    assert_equal 2, headers_frames.size, "Should have two HEADERS frames (103 + 200)"
    assert_equal 1, data_frames.size, "Should have one DATA frame"

    # First HEADERS = 103, second HEADERS = 200
    first_parser = Quicsilver::Protocol::ResponseParser.new(informational)
    first_parser.parse
    assert_equal 103, first_parser.status

    second_parser = Quicsilver::Protocol::ResponseParser.new(final)
    second_parser.parse
    assert_equal 200, second_parser.status
    assert_equal "<h1>Hello</h1>", second_parser.body.read
  end

  def test_multiple_1xx_then_200
    hints1 = encode_informational(103, { "link" => '</style.css>; rel=preload' })
    hints2 = encode_informational(103, { "link" => '</app.js>; rel=preload' })
    final = encode_final(200, { "content-type" => "text/html" }, ["<h1>Hello</h1>"])

    combined = hints1 + hints2 + final
    frames = parse_frames(combined)

    headers_frames = frames.select { |f| f[:type] == 0x01 }
    assert_equal 3, headers_frames.size, "Should have three HEADERS frames (103 + 103 + 200)"
  end

  # === Validation ===

  def test_informational_rejects_non_1xx_status
    assert_raises(ArgumentError) do
      encode_informational(200, {})
    end
  end

  def test_informational_accepts_199
    # 199 is valid 1xx per HTTP semantics — nothing in the spec forbids it
    data = encode_informational(199, {})
    parser = Quicsilver::Protocol::ResponseParser.new(data)
    parser.parse
    assert_equal 199, parser.status
  end

  def test_informational_accepts_100_through_103
    [100, 101, 102, 103].each do |status|
      data = encode_informational(status, {})
      parser = Quicsilver::Protocol::ResponseParser.new(data)
      parser.parse
      assert_equal status, parser.status, "Should accept #{status}"
    end
  end

  # === Connection#send_informational ===

  def test_send_informational_sends_headers_without_fin
    sent_frames = []
    mock_stream = Minitest::Mock.new

    # send_informational should call send_stream with fin=false
    Quicsilver.stub(:send_stream, ->(handle, data, fin) {
      sent_frames << { handle: handle, data: data, fin: fin }
      true
    }) do
      connection = Quicsilver::Transport::Connection.new(1, [1, 2])
      mock_handle = Object.new
      stream = Quicsilver::Transport::InboundStream.new(4)
      stream.stream_handle = mock_handle

      connection.send_informational(stream, 103, { "link" => '</style.css>; rel=preload' })

      assert_equal 1, sent_frames.size
      assert_equal false, sent_frames[0][:fin], "Informational MUST NOT set FIN"
      assert_equal mock_handle, sent_frames[0][:handle]

      # Verify the sent data is a valid 103 response
      parser = Quicsilver::Protocol::ResponseParser.new(sent_frames[0][:data])
      parser.parse
      assert_equal 103, parser.status
      assert_equal '</style.css>; rel=preload', parser.headers["link"]
    end
  end

  private

  def encode_informational(status, headers)
    Quicsilver::Protocol::ResponseEncoder.encode_informational(status, headers)
  end

  def encode_final(status, headers, body)
    Quicsilver::Protocol::ResponseEncoder.new(status, headers, body).encode
  end

  def parse_frames(data)
    frames = []
    Quicsilver::Protocol::FrameReader.each(data) do |type, payload|
      frames << { type: type, payload: payload }
    end
    frames
  end
end
