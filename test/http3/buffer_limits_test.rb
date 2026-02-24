# frozen_string_literal: true

require_relative "../http3_test_helper"

class BufferLimitsTest < Minitest::Test
  include HTTP3TestHelpers

  def test_rejects_body_exceeding_max_body_size
    body = "x" * 1025
    data = build_request(post_headers, body)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_body_size: 1024)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  def test_accepts_body_within_max_body_size
    body = "x" * 1024
    data = build_request(post_headers, body)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_body_size: 1024)
    parser.parse

    assert_equal 1024, parser.body.size
  end

  def test_rejects_cumulative_data_frames_exceeding_limit
    data = build_request(post_headers, "x" * 600, "y" * 600)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_body_size: 1024)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  def test_no_body_limit_by_default
    body = "x" * 100_000
    data = build_request(post_headers, body)

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal 100_000, parser.body.size
  end

  def test_rejects_headers_block_exceeding_max_header_size
    big_value = "v" * 2000
    data = build_request(get_headers("x-big" => big_value))

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_header_size: 1024)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  def test_accepts_headers_block_within_max_header_size
    data = build_request(get_headers("x-small" => "ok"))

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_header_size: 4096)
    parser.parse

    assert_equal "ok", parser.headers["x-small"]
  end

  def test_no_header_size_limit_by_default
    big_value = "v" * 100_000
    data = build_request(get_headers("x-big" => big_value))

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal big_value, parser.headers["x-big"]
  end

  def test_rejects_too_many_headers
    headers = get_headers
    51.times { |i| headers["x-h-#{i}"] = "val" }
    data = build_request(headers)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_header_count: 50)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  def test_accepts_headers_within_count_limit
    headers = get_headers
    10.times { |i| headers["x-h-#{i}"] = "val" }
    data = build_request(headers)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_header_count: 50)
    parser.parse

    assert_equal "val", parser.headers["x-h-0"]
  end

  def test_no_header_count_limit_by_default
    headers = get_headers
    200.times { |i| headers["x-h-#{i}"] = "val" }
    data = build_request(headers)

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal 200 + 4, parser.headers.size # 200 custom + 4 pseudo
  end

  def test_rejects_single_frame_exceeding_max_frame_size
    body = "x" * 2049
    data = build_request(post_headers, body)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_frame_payload_size: 2048)

    assert_raises(Quicsilver::HTTP3::FrameError) do
      parser.parse
    end
  end

  def test_accepts_frame_within_max_frame_size
    body = "x" * 2048
    data = build_request(post_headers, body)

    parser = Quicsilver::HTTP3::RequestParser.new(data, max_frame_payload_size: 2048)
    parser.parse

    assert_equal 2048, parser.body.size
  end

  def test_no_frame_size_limit_by_default
    body = "x" * 100_000
    data = build_request(post_headers, body)

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse

    assert_equal 100_000, parser.body.size
  end

  def test_response_rejects_body_exceeding_limit
    data = build_response(200, {}, "x" * 1025)

    parser = Quicsilver::HTTP3::ResponseParser.new(data, max_body_size: 1024)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  def test_response_rejects_header_size_exceeding_limit
    big_value = "v" * 2000
    data = build_response(200, { "x-big" => big_value })

    parser = Quicsilver::HTTP3::ResponseParser.new(data, max_header_size: 1024)

    assert_raises(Quicsilver::HTTP3::MessageError) do
      parser.parse
    end
  end

  def test_response_accepts_within_limits
    data = build_response(200, { "content-type" => "text/plain" }, "hello")

    parser = Quicsilver::HTTP3::ResponseParser.new(data, max_body_size: 1024, max_header_size: 4096)
    parser.parse

    assert_equal 200, parser.status
    assert_equal "hello", parser.body.read
  end
end
