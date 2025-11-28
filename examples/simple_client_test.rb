#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"

puts "🔌 Simple HTTP/3 Client Test"
puts "=" * 40

begin
  client = Quicsilver::Client.new("127.0.0.1", 4433, unsecure: true)

  client.connect

  response = client.get("/posts")

  puts "Status: #{response[:status]}"
  puts "Headers: #{response[:headers].inspect}"
  puts "Body: #{response[:body]}"

rescue => e
  puts "❌ Error: #{e.class} - #{e.message}"
  puts e.backtrace.first(10)
ensure
  client&.disconnect
  puts "👋 Done"
end
