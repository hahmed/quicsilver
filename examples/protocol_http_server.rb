#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Running a Rack app with protocol-http as the internal layer
#
# quicsilver uses protocol-http Request/Response internally.
# Rack apps are automatically wrapped — no code changes needed.
#
# Modes:
#   :rack (default) — Rack app, wrapped with Protocol::Rack::Adapter
#   :falcon         — native protocol-http app, no wrapping

require_relative "example_helper"

# Any standard Rack app works
app = ->(env) {
  puts "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} #{env['SERVER_PROTOCOL']}"

  body = "Hello from Quicsilver!\n" \
         "Method: #{env['REQUEST_METHOD']}\n" \
         "Path: #{env['PATH_INFO']}\n" \
         "Protocol: #{env['SERVER_PROTOCOL']}\n"

  [200, { "content-type" => "text/plain" }, [body]]
}

server = Quicsilver::Server.new(4433, app: app, server_configuration: EXAMPLE_TLS_CONFIG)

puts "Starting Quicsilver on https://localhost:4433"
puts "Test with: curl --http3 -k https://localhost:4433/"
server.start
