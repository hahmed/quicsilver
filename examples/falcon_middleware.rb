#!/usr/bin/env ruby

# Quicsilver with Falcon's middleware stack over HTTP/3.
#
# Falcon provides caching, content encoding, and protocol-rack.
# Quicsilver provides the HTTP/3 transport.
#
# Prerequisites: gem install falcon
#
#   ruby examples/falcon_middleware.rb
#   curl --http3-only -k https://localhost:4433/

require_relative "example_helper"

begin
  require "falcon"
rescue LoadError
  puts "❌ Falcon not installed. Run: gem install falcon"
  exit 1
end

app = ->(env) {
  [200, { "content-type" => "application/json" }, [
    %({"protocol":"#{env['SERVER_PROTOCOL']}","server":"quicsilver+falcon"})
  ]]
}

# Falcon's middleware adds caching, content encoding, etc.
middleware = Falcon::Server.middleware(app)

config = Quicsilver::Transport::Configuration.new(
  EXAMPLE_TLS_CONFIG.cert_file,
  EXAMPLE_TLS_CONFIG.key_file,
  mode: :falcon
)

server = Quicsilver::Server.new(4433, app: middleware, server_configuration: config)

puts "🦅 Quicsilver + Falcon Middleware"
puts "   https://localhost:4433"
puts "   curl --http3-only -k https://localhost:4433/"
puts

server.start
