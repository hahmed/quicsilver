# frozen_string_literal: true

require_relative "../http3_test_helper"

class EarlyDataValidationTest < Minitest::Test
  include HTTP3TestHelpers

  # RFC 9114 §4.2.2: 0-RTT requests MUST be safe (replay-safe).
  # Safe methods: GET, HEAD, OPTIONS (RFC 9110 §9.2.1)

  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
  UNSAFE_METHODS = %w[POST PUT DELETE PATCH].freeze

  SAFE_METHODS.each do |method|
    define_method("test_allows_#{method.downcase}_on_early_data") do
      headers = { ":method" => method, ":scheme" => "https",
                  ":authority" => "localhost", ":path" => "/" }
      data = build_request(headers)

      parser = Quicsilver::HTTP3::RequestParser.new(data)
      parser.parse
      parser.validate_headers!(early_data: true)
    end
  end

  UNSAFE_METHODS.each do |method|
    define_method("test_rejects_#{method.downcase}_on_early_data") do
      headers = { ":method" => method, ":scheme" => "https",
                  ":authority" => "localhost", ":path" => "/" }
      data = build_request(headers)

      parser = Quicsilver::HTTP3::RequestParser.new(data)
      parser.parse

      assert_raises(Quicsilver::HTTP3::MessageError) do
        parser.validate_headers!(early_data: true)
      end
    end
  end

  UNSAFE_METHODS.each do |method|
    define_method("test_allows_#{method.downcase}_on_normal_data") do
      headers = { ":method" => method, ":scheme" => "https",
                  ":authority" => "localhost", ":path" => "/" }
      data = build_request(headers)

      parser = Quicsilver::HTTP3::RequestParser.new(data)
      parser.parse
      parser.validate_headers!(early_data: false)
    end
  end

  def test_allows_unsafe_method_when_early_data_not_specified
    data = build_request(post_headers)

    parser = Quicsilver::HTTP3::RequestParser.new(data)
    parser.parse
    parser.validate_headers!
  end
end
