# frozen_string_literal: true

require_relative "../test_helper"

class StreamingDispatchTest < Minitest::Test
  # --- PendingStream ---

  def test_pending_stream_complete_and_wait
    pending = Quicsilver::Server::PendingStream.new(
      connection: nil, body: nil, request: nil, stream_id: 0
    )

    thread = Thread.new { pending.wait_for_handle(timeout: 2) }
    pending.complete(42)

    assert_equal 42, thread.value
  end

  def test_pending_stream_wait_timeout
    pending = Quicsilver::Server::PendingStream.new(
      connection: nil, body: nil, request: nil, stream_id: 0
    )

    result = pending.wait_for_handle(timeout: 0.05)
    assert_nil result
  end

  # --- contains_headers_frame? ---

  # --- StreamInput content-length validation ---

  def test_stream_input_validates_content_length_on_close
    body = Quicsilver::Protocol::StreamInput.new(10)
    body.write("hello")  # 5 bytes, expected 10

    assert_raises(Quicsilver::Protocol::MessageError) do
      body.close_write
    end
  end

  def test_stream_input_passes_when_content_length_matches
    body = Quicsilver::Protocol::StreamInput.new(5)
    body.write("hello")
    body.close_write  # should not raise

    assert body.closed?
  end

  def test_stream_input_skips_validation_without_content_length
    body = Quicsilver::Protocol::StreamInput.new(nil)
    body.write("any amount of data")
    body.close_write  # should not raise

    assert body.closed?
  end

  def test_stream_input_validates_across_multiple_writes
    body = Quicsilver::Protocol::StreamInput.new(10)
    body.write("hello")  # 5
    body.write("world")  # 10 total
    body.close_write  # should not raise

    assert body.closed?
  end

  # --- Adapter#send_response paths ---

  def test_send_response_nil_body
    adapter = Quicsilver::Protocol::Adapter.new(->(_) {})
    response = Protocol::HTTP::Response.new("HTTP/3", 204, Protocol::HTTP::Headers.new, nil)

    sent = []
    writer = ->(data, fin) { sent << [data, fin] }
    adapter.send_response(response, writer)

    assert_equal 1, sent.size
    assert sent[0][1], "should send with FIN"
  end

  def test_send_response_head_request
    adapter = Quicsilver::Protocol::Adapter.new(->(_) {})
    body = Protocol::HTTP::Body::Buffered.wrap("hello")
    response = Protocol::HTTP::Response.new("HTTP/3", 200, Protocol::HTTP::Headers.new, body)

    sent = []
    writer = ->(data, fin) { sent << [data, fin] }
    adapter.send_response(response, writer, head_request: true)

    assert_equal 1, sent.size
    assert sent[0][1], "should send with FIN"
    # Should not contain body data
    refute_includes sent[0][0], "hello"
  end

  def test_send_response_buffered_body
    adapter = Quicsilver::Protocol::Adapter.new(->(_) {})
    response = Protocol::HTTP::Response.new("HTTP/3", 200, Protocol::HTTP::Headers.new, ["hello"])

    sent = []
    writer = ->(data, fin) { sent << [data, fin] }
    adapter.send_response(response, writer)

    assert_equal 1, sent.size
    assert sent[0][1], "should send with FIN"
  end

  def test_send_response_streaming_body
    adapter = Quicsilver::Protocol::Adapter.new(->(_) {})
    body = Protocol::HTTP::Body::Buffered.new(["chunk1", "chunk2"])
    response = Protocol::HTTP::Response.new("HTTP/3", 200, Protocol::HTTP::Headers.new, body)

    sent = []
    writer = ->(data, fin) { sent << [data, fin] }
    adapter.send_response(response, writer)

    # Streaming: first call is headers (no FIN), then data frames, last with FIN
    assert sent.size >= 2, "streaming should send headers then body"
    refute sent[0][1], "headers should not have FIN"
    assert sent[-1][1], "last frame should have FIN"
  end

  private

  def build_post_request(body_str)
    encoder = Quicsilver::Protocol::RequestEncoder.new(
      method: "POST", path: "/test",
      headers: { "content-length" => body_str.bytesize.to_s },
      body: body_str
    )
    encoder.encode
  end
end
