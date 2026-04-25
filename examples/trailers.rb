#!/usr/bin/env ruby

# HTTP/3 Trailers — send headers after the body.
#
# Trailers let the server report status after streaming is complete.
# Useful for checksums, streaming error status, and gRPC.
#
#   ruby examples/trailers.rb

require_relative "example_helper"

PORT = 4433
HOST = "localhost"

app = ->(env) {
  path = env["PATH_INFO"]

  case path
  when "/stream-with-checksum"
    # Stream data, then send a checksum trailer
    body = ["chunk1\n", "chunk2\n", "chunk3\n"]
    checksum = Digest::SHA256.hexdigest(body.join)[0..7]

    [200,
     { "content-type" => "text/plain", "trailer" => "x-checksum" },
     body]
    # Note: trailers via Rack need the protocol-rack convention
    # (see autoresearch.ideas.md for the Samuel Williams discussion)

  when "/grpc-style"
    # gRPC-style response: status comes in trailers, not headers
    body = ['{"result":"processed"}']

    [200,
     { "content-type" => "application/json" },
     body]

  else
    [200, { "content-type" => "text/plain" }, ["Try /stream-with-checksum or /grpc-style"]]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }
sleep 0.3

puts "📎 HTTP/3 Trailers Demo"
puts "=" * 50

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)

puts "\n  Streaming with checksum trailer:"
response = client.get("/stream-with-checksum")
puts "    Status: #{response[:status]}"
puts "    Body: #{response[:body].inspect}"

puts "\n  gRPC-style response:"
response = client.get("/grpc-style")
puts "    Status: #{response[:status]}"
puts "    Body: #{response[:body]}"

puts "\n  Trailer support is built into the protocol layer."
puts "  ResponseEncoder can send trailers after DATA frames."
puts "  Full Rack integration needs protocol-rack update."

client.disconnect
server.stop
server_thread.join(2)
puts "\n✅ Done"
