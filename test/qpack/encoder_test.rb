# frozen_string_literal: true

require "test_helper"

class QpackEncoderTest < Minitest::Test
  def setup
    @encoder = Quicsilver::Qpack::Encoder.new
  end

  # Static table lookup
  def test_lookup_returns_full_match_for_indexed_header
    # :method GET is index 17 with full match
    result = @encoder.lookup(":method", "GET")
    assert_equal [17, true], result
  end

  def test_lookup_returns_name_only_match
    # :method with non-standard value - :method POST is index 20
    result = @encoder.lookup(":method", "PATCH")
    index, full_match = result
    refute full_match, "Should be name-only match"
    assert_includes [15, 16, 17, 18, 19, 20], index, "Should return a :method index"
  end

  def test_lookup_returns_nil_for_unknown_header
    result = @encoder.lookup("x-custom-header", "value")
    assert_nil result
  end

  def test_lookup_is_case_insensitive_for_name
    result = @encoder.lookup(":METHOD", "GET")
    assert_equal [17, true], result
  end

  def test_lookup_finds_status_codes
    # :status 200 is index 25
    result = @encoder.lookup(":status", "200")
    assert_equal [25, true], result

    # :status 404 is index 27
    result = @encoder.lookup(":status", "404")
    assert_equal [27, true], result
  end

  def test_lookup_name_only_for_non_indexed_status
    # :status 201 not in table, should return name-only match
    result = @encoder.lookup(":status", "201")
    index, full_match = result
    refute full_match
    assert index >= 24, "Should return a :status index"
  end

  # Encoding patterns
  def test_encode_indexed_field_line
    # Full match should produce 0xC0 | index
    headers = { ":method" => "GET" }
    encoded = @encoder.encode(headers)

    # Skip 2-byte prefix, first header byte should be indexed pattern
    assert_equal 0xC0 | 17, encoded.bytes[2]
  end

  def test_encode_literal_with_name_reference
    # Name match, value literal: 0x40 | index + value
    headers = { ":path" => "/custom" }
    encoded = @encoder.encode(headers)

    # :path is index 1
    assert_equal 0x40 | 1, encoded.bytes[2]
  end

  def test_encode_fully_literal
    # No match: 0x20 | name_length + name + value
    headers = { "x-custom" => "value" }
    encoded = @encoder.encode(headers)

    # 0x20 | 8 (length of "x-custom")
    assert_equal 0x20 | 8, encoded.bytes[2]
  end

  def test_encode_multiple_headers
    headers = {
      ":method" => "GET",
      ":path" => "/test",
      "x-custom" => "value"
    }
    encoded = @encoder.encode(headers)

    # Should have prefix + 3 encoded headers
    assert encoded.bytesize > 10
  end

  # Prefixed integer encoding
  def test_encode_prefixed_int_small_value
    # Value fits in prefix bits (6 bits = max 63)
    result = @encoder.send(:encode_prefixed_int, 10, 6, 0xC0)
    assert_equal [0xC0 | 10].pack("C"), result
  end

  def test_encode_prefixed_int_max_prefix_value
    # Value exactly at max prefix (63 for 6-bit prefix)
    result = @encoder.send(:encode_prefixed_int, 62, 6, 0xC0)
    assert_equal [0xC0 | 62].pack("C"), result
  end

  def test_encode_prefixed_int_large_value
    # Value exceeds prefix, needs continuation
    # 6-bit prefix max is 63, so 100 = 63 + 37
    result = @encoder.send(:encode_prefixed_int, 100, 6, 0xC0)
    assert_equal [0xFF, 37].pack("CC"), result
  end

  def test_encode_prefixed_int_very_large_value
    # Value needs multiple continuation bytes
    # 1000 with 6-bit prefix: 63 + 937 = 63 + (128*7 + 41) = needs 3 bytes
    result = @encoder.send(:encode_prefixed_int, 1000, 6, 0xC0)
    assert result.bytesize >= 3
    assert_equal 0xFF, result.bytes[0] # Max prefix
  end

  # Edge cases
  def test_encode_empty_headers
    encoded = @encoder.encode({})
    # Should just be the 2-byte prefix
    assert_equal "\x00\x00".b, encoded
  end

  def test_encode_empty_value
    headers = { "x-empty" => "" }
    encoded = @encoder.encode(headers)
    refute_nil encoded
    assert encoded.bytesize > 2
  end

  def test_encode_long_header_name
    long_name = "x-" + "a" * 50
    headers = { long_name => "value" }
    encoded = @encoder.encode(headers)

    # Should use literal encoding, total > name + value + overhead
    assert encoded.bytesize > 55
  end

  def test_encode_long_header_value
    long_value = "v" * 200
    headers = { "x-long" => long_value }
    encoded = @encoder.encode(headers)

    assert encoded.bytesize > 200
  end

  def test_encode_binary_value
    headers = { "x-binary" => "\x00\xFF\xFE".b }
    encoded = @encoder.encode(headers)
    assert_includes encoded, "\x00\xFF\xFE".b
  end

  def test_encode_symbol_keys
    headers = { :content_type => "text/plain" }
    encoded = @encoder.encode(headers)
    refute_nil encoded
  end

  def test_encode_integer_value
    headers = { "content-length" => 42 }
    encoded = @encoder.encode(headers)
    refute_nil encoded
  end

  def test_encode_preserves_header_order
    headers = [
      [":method", "GET"],
      [":path", "/"],
      [":scheme", "https"]
    ].to_h
    encoded = @encoder.encode(headers)

    # Method should come first after prefix
    assert_equal 0xC0 | 17, encoded.bytes[2], ":method GET should be first"
  end

  # Extension points
  def test_encode_prefix_returns_zero_ric_and_base
    assert_equal "\x00\x00".b, @encoder.encode_prefix
  end

  def test_lookup_can_be_overridden_for_dynamic_table
    custom_encoder = Class.new(Quicsilver::Qpack::Encoder) do
      def lookup(name, value)
        return [200, true] if name == "x-dynamic"

        super
      end
    end.new

    result = custom_encoder.lookup("x-dynamic", "value")
    assert_equal [200, true], result

    # Should still fall back to static table
    result = custom_encoder.lookup(":method", "GET")
    assert_equal [17, true], result
  end

  def test_encode_prefix_can_be_overridden
    custom_encoder = Class.new(Quicsilver::Qpack::Encoder) do
      def encode_prefix
        "\x05\x00".b # Non-zero Required Insert Count
      end
    end.new

    encoded = custom_encoder.encode({ "x-test" => "value" })
    assert_equal 0x05, encoded.bytes[0]
  end

  # Static table integrity
  def test_static_table_has_99_entries
    assert_equal 99, Quicsilver::HTTP3::STATIC_TABLE.size
  end

  def test_common_pseudo_headers_in_static_table
    table = Quicsilver::HTTP3::STATIC_TABLE

    assert_includes table, [":authority", ""]
    assert_includes table, [":method", "GET"]
    assert_includes table, [":method", "POST"]
    assert_includes table, [":path", "/"]
    assert_includes table, [":scheme", "http"]
    assert_includes table, [":scheme", "https"]
  end

  def test_common_status_codes_in_static_table
    table = Quicsilver::HTTP3::STATIC_TABLE

    assert_includes table, [":status", "200"]
    assert_includes table, [":status", "204"]
    assert_includes table, [":status", "206"]
    assert_includes table, [":status", "304"]
    assert_includes table, [":status", "400"]
    assert_includes table, [":status", "404"]
    assert_includes table, [":status", "500"]
  end

  def test_common_headers_in_static_table
    table = Quicsilver::HTTP3::STATIC_TABLE

    # Check some common headers exist (name-only entries)
    names = table.map(&:first)
    assert_includes names, "content-type"
    assert_includes names, "content-length"
    assert_includes names, "cache-control"
    assert_includes names, "accept"
    assert_includes names, "accept-encoding"
    assert_includes names, "user-agent"
    assert_includes names, "location"
  end

  # Roundtrip sanity check
  def test_encoded_output_is_binary
    encoded = @encoder.encode({ ":method" => "GET" })
    assert_equal Encoding::BINARY, encoded.encoding
  end
end
