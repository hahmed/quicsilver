#!/usr/bin/env ruby
# Component micro-benchmarks using benchmark-ips.
# No server needed — pure in-process measurements.
#
# Usage: ruby benchmarks/components.rb

require "bundler/setup"
require "quicsilver"
require "benchmark/ips"

# --- Varint ---

puts "=" * 60
puts "Varint encode/decode"
puts "=" * 60

small  = 6
medium = 1_000
large  = 1_000_000

encoded_small  = Quicsilver::HTTP3.encode_varint(small)
encoded_medium = Quicsilver::HTTP3.encode_varint(medium)
encoded_large  = Quicsilver::HTTP3.encode_varint(large)

Benchmark.ips do |x|
  x.config(warmup: 1, time: 3)

  x.report("encode small (#{small})")     { Quicsilver::HTTP3.encode_varint(small) }
  x.report("encode medium (#{medium})")   { Quicsilver::HTTP3.encode_varint(medium) }
  x.report("encode large (#{large})")     { Quicsilver::HTTP3.encode_varint(large) }
  x.report("decode small")   { Quicsilver::HTTP3.decode_varint(encoded_small.bytes, 0) }
  x.report("decode medium")  { Quicsilver::HTTP3.decode_varint(encoded_medium.bytes, 0) }
  x.report("decode large")   { Quicsilver::HTTP3.decode_varint(encoded_large.bytes, 0) }

  x.compare!
end

# --- Huffman ---

puts
puts "=" * 60
puts "Huffman encode/decode"
puts "=" * 60

huffman_inputs = [
  "www.example.com",
  "application/json",
  "text/html; charset=utf-8",
  "GET",
  "/api/v1/users?page=1&limit=50"
]

encoded_huffman = huffman_inputs.map { |s| Quicsilver::Qpack::HuffmanCode.encode(s) }

Benchmark.ips do |x|
  x.config(warmup: 1, time: 3)

  huffman_inputs.each do |input|
    x.report("encode #{input[0..20]}") { Quicsilver::Qpack::HuffmanCode.encode(input) }
  end
  encoded_huffman.each_with_index do |enc, i|
    x.report("decode #{huffman_inputs[i][0..20]}") { Quicsilver::Qpack::HuffmanCode.decode(enc) }
  end

  x.compare!
end

# --- QPACK Encoder ---

puts
puts "=" * 60
puts "QPACK Encoder"
puts "=" * 60

headers = [
  [":method", "GET"],
  [":path", "/api/v1/users"],
  [":scheme", "https"],
  [":authority", "example.com"],
  ["accept", "application/json"],
  ["user-agent", "quicsilver-bench/1.0"],
  ["accept-encoding", "gzip, deflate"]
]

encoder_huffman = Quicsilver::Qpack::Encoder.new(huffman: true)
encoder_raw     = Quicsilver::Qpack::Encoder.new(huffman: false)

Benchmark.ips do |x|
  x.config(warmup: 1, time: 3)

  x.report("encode (huffman on)")  { encoder_huffman.encode(headers) }
  x.report("encode (huffman off)") { encoder_raw.encode(headers) }

  x.compare!
end

# --- QPACK Decoder ---

puts
puts "=" * 60
puts "QPACK Decoder (string decoding)"
puts "=" * 60

# Build payloads for decode_qpack_string
huffman_payload = Quicsilver::Qpack::HuffmanCode.encode("application/json")
huffman_bytes = [0x80 | huffman_payload.bytesize] + huffman_payload.bytes  # Huffman flag set

raw_string = "application/json"
raw_bytes = [raw_string.bytesize] + raw_string.bytes  # No Huffman flag

# Include the decoder module in a throwaway object
decoder = Object.new
decoder.extend(Quicsilver::Qpack::Decoder)

Benchmark.ips do |x|
  x.config(warmup: 1, time: 3)

  x.report("decode huffman string") { decoder.decode_qpack_string(huffman_bytes, 0) }
  x.report("decode raw string")     { decoder.decode_qpack_string(raw_bytes, 0) }

  x.compare!
end

# --- Request Parser ---

puts
puts "=" * 60
puts "Request Parser"
puts "=" * 60

# Build a realistic GET request frame
request_encoder = Quicsilver::Qpack::Encoder.new(huffman: true)
request_headers_payload = request_encoder.encode([
  [":method", "GET"],
  [":path", "/api/v1/users?page=1"],
  [":scheme", "https"],
  [":authority", "example.com"],
  ["accept", "application/json"],
  ["user-agent", "quicsilver-bench/1.0"]
])

# HEADERS frame: type=0x01, varint length, payload
request_frame = Quicsilver::HTTP3.encode_varint(0x01) +
  Quicsilver::HTTP3.encode_varint(request_headers_payload.bytesize) +
  request_headers_payload

Benchmark.ips do |x|
  x.config(warmup: 1, time: 3)

  x.report("parse GET request") do
    parser = Quicsilver::HTTP3::RequestParser.new(request_frame)
    parser.parse
  end

  x.compare!
end

# --- Response Parser ---

puts
puts "=" * 60
puts "Response Parser"
puts "=" * 60

# Build a realistic 200 response with body
response_encoder = Quicsilver::Qpack::Encoder.new(huffman: true)
response_headers_payload = response_encoder.encode([
  [":status", "200"],
  ["content-type", "application/json"],
  ["server", "quicsilver"]
])

body = '{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}'

response_frame = Quicsilver::HTTP3.encode_varint(0x01) +
  Quicsilver::HTTP3.encode_varint(response_headers_payload.bytesize) +
  response_headers_payload +
  Quicsilver::HTTP3.encode_varint(0x00) +
  Quicsilver::HTTP3.encode_varint(body.bytesize) +
  body

Benchmark.ips do |x|
  x.config(warmup: 1, time: 3)

  x.report("parse 200 response + body") do
    parser = Quicsilver::HTTP3::ResponseParser.new(response_frame)
    parser.parse
  end

  x.compare!
end
