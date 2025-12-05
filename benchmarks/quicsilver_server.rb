#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"
require 'localhost/authority'
require 'json'

SIMPLE_APP = lambda do |env|
  case env['PATH_INFO']
  when '/'
    [200, {'Content-Type' => 'text/plain'}, ['OK']]
  when '/json'
    body = JSON.generate({status: 'ok', timestamp: Time.now.to_i})
    [200, {'Content-Type' => 'application/json'}, [body]]
  when '/echo'
    [200, {'Content-Type' => 'text/plain'}, [env['REQUEST_METHOD']]]
  else
    [404, {'Content-Type' => 'text/plain'}, ['Not Found']]
  end
end

port = ENV["PORT"] || 4433
default_host = ENV["HOST"] || "0.0.0.0"

authority = Localhost::Authority.fetch
cert_file = authority.certificate_path
key_file = authority.key_path

config = ::Quicsilver::ServerConfiguration.new(cert_file, key_file)

server = ::Quicsilver::Server.new(
  port.to_i,
  address: default_host,
  app: SIMPLE_APP,
  server_configuration: config
)

puts "Starting Quicsilver on port #{port}..."
server.start

trap("INT") do
  puts "\nStopping server..."
  server.stop
  exit
end

sleep
