# frozen_string_literal: true

require_relative "../test_helper"

# Application error codes (draft-ietf-webtrans-http3-16 §4.4).
#
# WebTransport shares the HTTP/3 error space, so 32-bit application codes are
# mapped into a reserved range. Codepoints of the form 0x1f * N + 0x21 are
# reserved by HTTP/3 §8.1 and are skipped, which is why the mapping is not a
# plain offset.
class WebTransportErrorCodesTest < Minitest::Test
  Codes = Quicsilver::Protocol::WebTransport

  FIRST = 0x52e4a40fa8db
  LAST = 0x52e5ac983162
  MAX_APPLICATION_CODE = 0xffffffff

  def test_zero_maps_to_the_first_code_in_the_range
    assert_equal FIRST, Codes.application_error_to_http(0)
  end

  def test_the_largest_code_maps_to_the_last_in_the_range
    assert_equal LAST, Codes.application_error_to_http(MAX_APPLICATION_CODE)
  end

  def test_round_trips_across_the_range
    [0, 1, 29, 30, 31, 255, 65_535, 1_000_000, MAX_APPLICATION_CODE].each do |code|
      http = Codes.application_error_to_http(code)

      assert_equal code, Codes.http_to_application_error(http), "failed for #{code}"
    end
  end

  def test_never_produces_a_reserved_codepoint
    (0..200).each do |code|
      http = Codes.application_error_to_http(code)

      refute_equal 0, (http - 0x21) % 0x1f, "code #{code} mapped onto a reserved codepoint"
    end
  end

  # The skip logic is easy to get subtly wrong in a way fixed examples miss.
  def test_round_trips_random_codes
    2_000.times do
      code = rand(0..MAX_APPLICATION_CODE)
      http = Codes.application_error_to_http(code)

      assert_operator http, :>=, FIRST
      assert_operator http, :<=, LAST
      assert_equal code, Codes.http_to_application_error(http), "failed for #{code}"
    end
  end

  def test_rejects_codes_below_the_range
    assert_nil Codes.http_to_application_error(FIRST - 1)
  end

  def test_rejects_codes_above_the_range
    assert_nil Codes.http_to_application_error(LAST + 1)
  end

  def test_rejects_reserved_codepoints_inside_the_range
    reserved = (FIRST..FIRST + 200).find { |code| (code - 0x21) % 0x1f == 0 }

    refute_nil reserved, "expected a reserved codepoint near the start of the range"
    assert_nil Codes.http_to_application_error(reserved)
  end

  def test_application_error_range_is_exposed
    assert_equal FIRST, Codes::APPLICATION_ERROR_FIRST
    assert_equal LAST, Codes::APPLICATION_ERROR_LAST
  end
end
