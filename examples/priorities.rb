#!/usr/bin/env ruby

# HTTP/3 Extensible Priorities (RFC 9218).
#
# Browsers send priority hints: CSS is urgency 0 (highest),
# images are urgency 5 (low). Quicsilver parses these and tells
# MsQuic to send high-priority data first.
#
#   ruby examples/priorities.rb
#
# Then from another terminal, the client fires CSS and image
# requests and shows the priority was parsed.

require_relative "example_helper"

PORT = 4433
HOST = "localhost"

app = ->(env) {
  path = env["PATH_INFO"]

  case path
  when "/style.css"
    # Browsers send: priority: u=0 (highest urgency)
    [200, { "content-type" => "text/css" }, ["body { margin: 0; }\n" * 50]]
  when "/image.png"
    # Browsers send: priority: u=5 (low urgency)
    [200, { "content-type" => "image/png" }, ["x" * 10_000]]
  else
    [200, { "content-type" => "text/html" }, [
      "<link rel='stylesheet' href='/style.css'>\n<img src='/image.png'>\n"
    ]]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }
sleep 0.3

puts "🎯 HTTP/3 Priorities Demo"
puts "=" * 50

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)

# Request with priority header (what a browser would send)
puts "\n  CSS request (high priority):"
response = client.get("/style.css", headers: { "priority" => "u=0, i" })
puts "    Status: #{response[:status]}, Size: #{response[:body].bytesize} bytes"

puts "\n  Image request (low priority):"
response = client.get("/image.png", headers: { "priority" => "u=5" })
puts "    Status: #{response[:status]}, Size: #{response[:body].bytesize} bytes"

puts "\n  MsQuic schedules CSS data before image data"
puts "  when both are in flight on the same connection."

client.disconnect
server.stop
server_thread.join(2)
puts "\n✅ Done"
