# frozen_string_literal: true

require_relative "../http3_test_helper"

class ContentLengthValidationTest < Minitest::Test
  include HTTP3TestHelpers

  def test_rejects_content_length_greater_than_body
    data = build_request(post_headers("content-length" => "100"), "hello")

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_rejects_content_length_less_than_body
    data = build_request(post_headers("content-length" => "3"), "0123456789")

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_accepts_matching_content_length
    body = "hello world"
    data = build_request(post_headers("content-length" => body.bytesize.to_s), body)

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse
    parser.validate_headers!
  end

  def test_no_content_length_skips_validation
    data = build_request(post_headers, "any body")

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse
    parser.validate_headers!
  end

  def test_accepts_zero_content_length_with_no_body
    data = build_request(get_headers("content-length" => "0"))

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse
    parser.validate_headers!
  end

  def test_rejects_zero_content_length_with_body
    data = build_request(post_headers("content-length" => "0"), "unexpected")

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse

    assert_raises(Quicsilver::Protocol::MessageError) do
      parser.validate_headers!
    end
  end

  def test_accepts_content_length_matching_multiple_data_frames
    total = 8 # "abc" + "defgh"
    data = build_request(post_headers("content-length" => total.to_s), "abc", "defgh")

    parser = Quicsilver::Protocol::RequestParser.new(data)
    parser.parse
    parser.validate_headers!
  end
end
