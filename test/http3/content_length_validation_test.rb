# frozen_string_literal: true

require_relative "../http3_test_helper"

# Content-length validation is enforced by StreamInput#close_write (RFC 9114 §4.1.2).
# This validates that the total bytes written match the declared content-length,
# working for both buffered and streaming paths.
class ContentLengthValidationTest < Minitest::Test
  parallelize_me!
  include HTTP3TestHelpers

  def test_rejects_content_length_greater_than_body
    body = Quicsilver::Protocol::StreamInput.new(100)
    body.write("hello")  # 5 bytes, expected 100

    assert_raises(Quicsilver::Protocol::MessageError) do
      body.close_write
    end
  end

  def test_rejects_content_length_less_than_body
    body = Quicsilver::Protocol::StreamInput.new(3)
    body.write("0123456789")  # 10 bytes, expected 3

    assert_raises(Quicsilver::Protocol::MessageError) do
      body.close_write
    end
  end

  def test_accepts_matching_content_length
    body = Quicsilver::Protocol::StreamInput.new(11)
    body.write("hello world")
    body.close_write  # should not raise
  end

  def test_no_content_length_skips_validation
    body = Quicsilver::Protocol::StreamInput.new(nil)
    body.write("any body")
    body.close_write  # should not raise
  end

  def test_accepts_zero_content_length_with_no_body
    body = Quicsilver::Protocol::StreamInput.new(0)
    body.close_write  # should not raise
  end

  def test_rejects_zero_content_length_with_body
    body = Quicsilver::Protocol::StreamInput.new(0)
    body.write("unexpected")

    assert_raises(Quicsilver::Protocol::MessageError) do
      body.close_write
    end
  end

  def test_accepts_content_length_matching_multiple_writes
    body = Quicsilver::Protocol::StreamInput.new(8)
    body.write("abc")
    body.write("defgh")
    body.close_write  # should not raise
  end
end
