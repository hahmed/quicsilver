# frozen_string_literal: true

require "test_helper"
require "quicsilver/qpack/huffman_code"

class HuffmanCodeTest < Minitest::Test
  HuffmanCode = Quicsilver::Qpack::HuffmanCode

  # Table integrity
  def test_table_has_256_entries
    assert_equal 256, HuffmanCode::TABLE.size
  end

  def test_table_covers_all_byte_values
    (0..255).each do |byte|
      assert HuffmanCode::TABLE.key?(byte), "Missing entry for byte #{byte}"
    end
  end

  def test_all_codes_fit_within_declared_bit_length
    HuffmanCode::TABLE.each do |byte, (code, bit_length)|
      assert code < (1 << bit_length),
        "Byte #{byte}: code 0x#{code.to_s(16)} doesn't fit in #{bit_length} bits"
    end
  end

  def test_eos_symbol
    code, length = HuffmanCode::EOS
    assert_equal 0x3fffffff, code
    assert_equal 30, length
  end

  # Encode — single characters
  def test_encode_single_byte_0
    # '0' (48) => 0x0, 5 bits => 00000 + 111 pad => 0x07
    result = HuffmanCode.encode("0")
    assert_equal [0x07].pack("C"), result
  end

  def test_encode_single_byte_a
    # 'a' (97) => 0x3, 5 bits => 00011 + 111 pad => 0x1f
    result = HuffmanCode.encode("a")
    assert_equal [0x1f].pack("C"), result
  end

  def test_encode_single_byte_space
    # ' ' (32) => 0x14, 6 bits => 010100 + 11 pad => 0x53
    result = HuffmanCode.encode(" ")
    assert_equal [0x53].pack("C"), result
  end

  # Encode — known RFC 7541 examples
  # RFC 7541 §C.4.1: :path /sample/path encodes headers using Huffman
  def test_encode_www_example_com
    # From RFC 7541 C.4.1 — "www.example.com" Huffman encoding
    input = "www.example.com"
    expected = [0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff].pack("C*")
    assert_equal expected, HuffmanCode.encode(input)
  end

  def test_encode_no_cache
    # From RFC 7541 C.4.1 — "no-cache"
    input = "no-cache"
    expected = [0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf].pack("C*")
    assert_equal expected, HuffmanCode.encode(input)
  end

  def test_encode_custom_key
    # From RFC 7541 C.4.2 — "custom-key"
    input = "custom-key"
    expected = [0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f].pack("C*")
    assert_equal expected, HuffmanCode.encode(input)
  end

  def test_encode_custom_value
    # From RFC 7541 C.4.2 — "custom-value"
    input = "custom-value"
    expected = [0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf].pack("C*")
    assert_equal expected, HuffmanCode.encode(input)
  end

  # Encode — properties
  def test_encode_returns_binary_encoding
    result = HuffmanCode.encode("hello")
    assert_equal Encoding::BINARY, result.encoding
  end

  def test_encode_empty_string
    result = HuffmanCode.encode("")
    assert_equal "".b, result
  end

  def test_encode_padding_is_all_ones
    # Last byte's trailing bits must be 1s (EOS prefix)
    result = HuffmanCode.encode("a") # 5 bits => 3 pad bits, all 1
    last_byte = result.bytes.last
    # 'a' = 00011, pad = 111 => 00011_111 = 0x1f
    assert_equal 0x1f, last_byte
  end

  def test_encode_is_shorter_than_raw_for_typical_headers
    typical = "text/html; charset=utf-8"
    encoded = HuffmanCode.encode(typical)
    assert encoded.bytesize < typical.bytesize,
      "Huffman should compress typical header values (#{encoded.bytesize} >= #{typical.bytesize})"
  end

  def test_encode_common_header_values
    # These are all common HTTP header values that should compress well
    %w[gzip deflate keep-alive close GET POST application/json].each do |val|
      encoded = HuffmanCode.encode(val)
      assert encoded.bytesize <= val.bytesize,
        "#{val}: Huffman (#{encoded.bytesize}) should be <= raw (#{val.bytesize})"
    end
  end

  # Encode — byte alignment
  def test_encode_exact_byte_boundary
    # '0' '1' = 5+5 = 10 bits => 6 pad => 2 bytes
    result = HuffmanCode.encode("01")
    assert_equal 2, result.bytesize
  end

  def test_encode_multiple_bytes_alignment
    # 'e' (5) + 'e' (5) + 'e' (5) + 'e' (5) + 'e' (5) = 25 bits => 7 pad => 4 bytes
    result = HuffmanCode.encode("eeeee")
    assert_equal 4, result.bytesize
  end

  # Decode — RFC 7541 examples
  def test_decode_www_example_com
    encoded = [0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff].pack("C*")
    assert_equal "www.example.com", HuffmanCode.decode(encoded)
  end

  def test_decode_no_cache
    encoded = [0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf].pack("C*")
    assert_equal "no-cache", HuffmanCode.decode(encoded)
  end

  def test_decode_custom_key
    encoded = [0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f].pack("C*")
    assert_equal "custom-key", HuffmanCode.decode(encoded)
  end

  def test_decode_custom_value
    encoded = [0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf].pack("C*")
    assert_equal "custom-value", HuffmanCode.decode(encoded)
  end

  def test_decode_empty
    assert_equal "".b, HuffmanCode.decode("".b)
  end

  def test_decode_returns_binary_encoding
    encoded = HuffmanCode.encode("hello")
    assert_equal Encoding::BINARY, HuffmanCode.decode(encoded).encoding
  end

  # Decode — invalid input
  def test_decode_returns_nil_for_invalid_code
    # All zeros can't be a valid ending (no valid padding)
    assert_nil HuffmanCode.decode([0x00].pack("C"))
  end

  # Roundtrip
  def test_roundtrip_ascii_printable
    (32..126).each do |byte|
      char = byte.chr
      assert_equal char.b, HuffmanCode.decode(HuffmanCode.encode(char)),
        "Roundtrip failed for byte #{byte} (#{char})"
    end
  end

  def test_roundtrip_typical_header_values
    values = [
      "text/html",
      "application/json; charset=utf-8",
      "gzip, deflate, br",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
      "https://example.com/path?query=1&foo=bar",
      "keep-alive",
      "max-age=31536000",
      "Thu, 01 Jan 2026 00:00:00 GMT",
    ]
    values.each do |val|
      assert_equal val.b, HuffmanCode.decode(HuffmanCode.encode(val)),
        "Roundtrip failed for: #{val}"
    end
  end

  def test_roundtrip_all_single_bytes
    (0..255).each do |byte|
      str = [byte].pack("C")
      assert_equal str, HuffmanCode.decode(HuffmanCode.encode(str)),
        "Roundtrip failed for byte #{byte}"
    end
  end

  # Reverse table integrity
  def test_reverse_table_exists
    refute_empty HuffmanCode::REVERSE_TABLE
  end

  def test_reverse_table_root_has_two_branches
    assert HuffmanCode::REVERSE_TABLE.key?(0), "Missing 0-branch"
    assert HuffmanCode::REVERSE_TABLE.key?(1), "Missing 1-branch"
  end
end
