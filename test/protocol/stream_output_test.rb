# frozen_string_literal: true

require_relative "../test_helper"
require "quicsilver/protocol/stream_output"
require "protocol/http/body/readable"

class Quicsilver::Protocol::StreamOutputTest < Minitest::Test
  class ArrayBody < Protocol::HTTP::Body::Readable
    def initialize(chunks)
      @chunks = chunks.dup
      @closed = false
    end

    def read
      @chunks.shift
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  def test_single_chunk_sends_with_fin
    body = ArrayBody.new(["hello"])
    sent = []
    output = Quicsilver::Protocol::StreamOutput.new(body) { |data, fin| sent << [data, fin] }
    output.stream

    assert_equal 1, sent.size
    assert sent[0][1], "single chunk should have FIN"
    assert body.closed?
  end

  def test_multiple_chunks_fin_only_on_last
    body = ArrayBody.new(["a", "b", "c"])
    sent = []
    output = Quicsilver::Protocol::StreamOutput.new(body) { |data, fin| sent << [data.dup, fin] }
    output.stream

    assert_equal 3, sent.size
    refute sent[0][1]
    refute sent[1][1]
    assert sent[2][1], "only last chunk should have FIN"
  end

  def test_closes_body_on_error
    body = ArrayBody.new(["data"])
    output = Quicsilver::Protocol::StreamOutput.new(body) { |data, fin| raise "send failed" }

    assert_raises(RuntimeError) { output.stream }
    assert body.closed?
  end

  def test_data_frames_are_valid_http3
    body = ArrayBody.new(["test"])
    sent = []
    output = Quicsilver::Protocol::StreamOutput.new(body) { |data, fin| sent << data }
    output.stream

    frame = sent[0]
    assert_equal 0x00, frame.getbyte(0), "frame type should be DATA (0x00)"
    assert_equal 4, frame.getbyte(1), "payload length should be 4"
    assert_equal "test", frame[2..].force_encoding("UTF-8")
  end
end
