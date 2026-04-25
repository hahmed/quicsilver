#!/usr/bin/env ruby

# Server-Sent Events over HTTP/3.
#
# Demonstrates streaming responses — data arrives chunk by chunk,
# not buffered. Each chunk is sent as a separate HTTP/3 DATA frame.
#
#   ruby examples/streaming_sse.rb
#   curl --http3-only -k https://localhost:4433/

require_relative "example_helper"

app = ->(env) {
  body = Enumerator.new do |y|
    10.times do |i|
      y << "data: {\"count\":#{i},\"time\":\"#{Time.now.iso8601}\"}\n\n"
      sleep 0.2
    end
    y << "data: {\"done\":true}\n\n"
  end

  [200, { "content-type" => "text/event-stream", "cache-control" => "no-cache" }, body]
}

server = Quicsilver::Server.new(4433, app: app, server_configuration: EXAMPLE_TLS_CONFIG)

puts "📡 Streaming SSE over HTTP/3"
puts "   https://localhost:4433"
puts "   curl --http3-only -k https://localhost:4433/"
puts "   Events arrive every 200ms — no buffering."
puts

server.start
