#!/usr/bin/env ruby

# HTTP/3 Trailers — send headers after the body.
#
# Trailers let the server report status after streaming is complete.
# Useful for checksums, streaming error status, and gRPC.
#
#   ruby examples/trailers.rb

require_relative "example_helper"
require "digest"

PORT = 4433
HOST = "localhost"

app = ->(env) {
  path = env["PATH_INFO"]

  case path
  when "/stream-with-checksum"
    body = ["chunk1\n", "chunk2\n", "chunk3\n"]
    checksum = Digest::SHA256.hexdigest(body.join)[0..7]
    env["rack.trailers"] = { "x-checksum" => checksum }
    [200, { "content-type" => "text/plain" }, body]

  when "/grpc-style"
    env["rack.trailers"] = { "grpc-status" => "0", "grpc-message" => "OK" }
    [200, { "content-type" => "application/grpc" }, ['{"result":"processed"}']]

  when "/grpc-error"
    env["rack.trailers"] = { "grpc-status" => "13", "grpc-message" => "INTERNAL" }
    [200, { "content-type" => "application/grpc" }, ['{"error":"something broke"}']]

  else
    [200, { "content-type" => "text/plain" }, ["Try /stream-with-checksum, /grpc-style, or /grpc-error"]]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }
sleep 0.3

puts "HTTP/3 Trailers Demo"
puts "=" * 50

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)

puts "\n  Streaming with checksum trailer:"
response = client.get("/stream-with-checksum")
puts "    Status:   #{response.status}"
puts "    Body:     #{response.body.inspect}"
puts "    Trailers: #{response.trailers}"

puts "\n  gRPC-style success:"
response = client.get("/grpc-style")
puts "    Status:   #{response.status}"
puts "    Body:     #{response.body}"
puts "    Trailers: #{response.trailers}"

puts "\n  gRPC-style error:"
response = client.get("/grpc-error")
puts "    Status:   #{response.status}"
puts "    Body:     #{response.body}"
puts "    Trailers: #{response.trailers}"

client.disconnect
server.stop
server_thread.join(2)
puts "\nDone"
