# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "set"
require "quicsilver/http3"
require "quicsilver/qpack/huffman_code"
require "quicsilver/qpack/decoder"
require "quicsilver/qpack/encoder"
require "quicsilver/qpack/header_block_decoder"
require "quicsilver/http3/request_parser"
require "quicsilver/http3/response_parser"

require "minitest/autorun"

module HTTP3TestHelpers
  def build_frame(type, payload)
    Quicsilver::HTTP3.encode_varint(type) +
      Quicsilver::HTTP3.encode_varint(payload.bytesize) +
      payload
  end

  def build_headers_frame(payload)
    build_frame(Quicsilver::HTTP3::FRAME_HEADERS, payload)
  end

  def build_data_frame(payload)
    build_frame(Quicsilver::HTTP3::FRAME_DATA, payload)
  end

  def encode_varint(value)
    Quicsilver::HTTP3.encode_varint(value)
  end

  def build_qpack_headers(headers)
    Quicsilver::Qpack::Encoder.new(huffman: false).encode(headers)
  end

  def build_qpack_response_headers(status, headers = {})
    Quicsilver::Qpack::Encoder.new(huffman: false).encode(
      { ":status" => status.to_s }.merge(headers)
    )
  end

  # Build a complete HTTP/3 request message (HEADERS + optional DATA frames).
  #   build_request({ ":method" => "GET", ... })
  #   build_request({ ":method" => "POST", ... }, "body")
  #   build_request(headers, "chunk1", "chunk2")
  def build_request(headers, *body_chunks)
    data = build_headers_frame(build_qpack_headers(headers))
    body_chunks.each { |chunk| data += build_data_frame(chunk) }
    data
  end

  # Build a complete HTTP/3 response message (HEADERS + optional DATA frames).
  #   build_response(200, { "content-type" => "text/plain" })
  #   build_response(200, {}, "body")
  #   build_response(200, {}, "chunk1", "chunk2")
  def build_response(status, headers = {}, *body_chunks)
    data = build_headers_frame(build_qpack_response_headers(status, headers))
    body_chunks.each { |chunk| data += build_data_frame(chunk) }
    data
  end

  def get_headers(extra = {})
    { ":method" => "GET", ":scheme" => "https",
      ":authority" => "localhost", ":path" => "/" }.merge(extra)
  end

  def post_headers(extra = {})
    { ":method" => "POST", ":scheme" => "https",
      ":authority" => "localhost", ":path" => "/" }.merge(extra)
  end

  def qpack_prefix
    "\x00\x00".b
  end

  # Encode a literal header field with literal name (QPACK pattern 5: 001xxxxx).
  # Bypasses the encoder to produce arbitrary/invalid sequences for testing.
  def encode_literal(name, value)
    name_bytes = name.b
    value_bytes = value.b
    out = "".b
    out << encode_prefixed_int(name_bytes.bytesize, 3, 0x20)
    out << name_bytes
    out << encode_prefixed_int(value_bytes.bytesize, 7, 0x00)
    out << value_bytes
    out
  end

  def encode_prefixed_int(value, prefix_bits, pattern)
    max_prefix = (1 << prefix_bits) - 1
    if value < max_prefix
      [pattern | value].pack("C")
    else
      out = [pattern | max_prefix].pack("C")
      value -= max_prefix
      while value >= 128
        out << [(value & 0x7F) | 0x80].pack("C")
        value >>= 7
      end
      out << [value].pack("C")
      out
    end
  end
end
