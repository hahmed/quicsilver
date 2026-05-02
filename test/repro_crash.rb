#!/usr/bin/env ruby
# Reproduction of SIGABRT in MsQuic thread pool mode.
# Tests many servers/clients cycling in one process — simulates rake test.

$LOAD_PATH.unshift File.join(__dir__, "../lib")
require "bundler/setup"
require "quicsilver"

cert = File.join(__dir__, "data/certificates/server.crt")
key = File.join(__dir__, "data/certificates/server.key")

app = ->(env) {
  if env["PATH_INFO"] == "/crash"
    raise "intentional crash"
  end
  [200, {"content-type" => "text/plain"}, ["ok"]]
}

20.times do |round|
  port = 4600 + round
  config = Quicsilver::Transport::Configuration.new(cert, key)
  server = Quicsilver::Server.new(port, app: app, server_configuration: config)
  Thread.new { server.start }
  sleep 0.2

  client = Quicsilver::Client.new("localhost", port, unsecure: true)

  # Normal
  resp = client.get("/ok")

  # Crash
  client.get("/crash") rescue nil

  # After crash
  resp = client.get("/ok")

  client.disconnect
  server.stop

  print "#{round + 1} "
end

puts "\nAll 20 rounds complete — no SIGABRT!"
