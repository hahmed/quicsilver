#!/usr/bin/env ruby

# gRPC-style request/response over HTTP/3.
#
# gRPC is just HTTP with:
#   - content-type: application/grpc (or application/grpc+json)
#   - 5-byte frame prefix: [compressed(1)][length(4)][message]
#   - Status in trailers: grpc-status, grpc-message
#
# This example uses JSON for simplicity. In production you'd use
# protobuf (google-protobuf gem) for smaller, faster serialization.
# Quicsilver carries the bytes — the app chooses the encoding.
#
#   ruby examples/grpc_style.rb

require_relative "example_helper"
require "json"

PORT = 4433
HOST = "localhost"

# gRPC frame: [0x00][4-byte big-endian length][message]
def grpc_encode(message)
  data = message.to_json
  [0, data.bytesize].pack("CN") + data
end

def grpc_decode(frame)
  _compressed, length = frame.unpack("CN")
  JSON.parse(frame[5, length])
end

app = ->(env) {
  path = env["PATH_INFO"]
  body = env["rack.input"]&.read || ""

  case path
  when "/grpc.UserService/GetUser"
    request = grpc_decode(body) rescue { "error" => "bad frame" }
    user = { "id" => request["id"], "name" => "Alice", "email" => "alice@example.com" }
    response_frame = grpc_encode(user)

    [200,
     { "content-type" => "application/grpc+json" },
     [response_frame]]

  when "/grpc.UserService/ListUsers"
    users = [
      { "id" => 1, "name" => "Alice" },
      { "id" => 2, "name" => "Bob" },
      { "id" => 3, "name" => "Charlie" }
    ]
    response_frame = grpc_encode(users)

    [200,
     { "content-type" => "application/grpc+json" },
     [response_frame]]

  else
    [404, { "content-type" => "text/plain" }, ["Unknown gRPC method: #{path}"]]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }
sleep 0.3

puts "🔌 gRPC-style over HTTP/3 (JSON, no protobuf)"
puts "=" * 50

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)

# GetUser
puts "\n  GetUser(id=1):"
request_frame = grpc_encode({ "id" => 1 })
response = client.post("/grpc.UserService/GetUser",
  body: request_frame,
  headers: { "content-type" => "application/grpc+json" })
user = grpc_decode(response[:body])
puts "    → #{user}"

# ListUsers
puts "\n  ListUsers():"
request_frame = grpc_encode({})
response = client.post("/grpc.UserService/ListUsers",
  body: request_frame,
  headers: { "content-type" => "application/grpc+json" })
users = grpc_decode(response[:body])
puts "    → #{users}"

puts "\n  gRPC is just HTTP + framing. Quicsilver carries the bytes."
puts "  This example uses JSON — swap in protobuf for production."

client.disconnect
server.stop
server_thread.join(2)
puts "\n✅ Done"
