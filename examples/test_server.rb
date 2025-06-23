#!/usr/bin/env ruby

require "bundler/setup"

puts "🔥 Quicsilver QUIC Server Test"
puts "═" * 40

# Certificate files (use the ones we created earlier)
cert_file = File.expand_path("../certs/server.crt", __dir__)
key_file = File.expand_path("../certs/server.key", __dir__)

# Check if certificate files exist
unless File.exist?(cert_file) && File.exist?(key_file)
  puts "❌ Certificate files not found!"
  puts "   Expected: #{cert_file}"
  puts "   Expected: #{key_file}"
  puts "   Please run the certificate creation script first."
  exit 1
end

begin
  # Kill any existing process on port 4433
  system("lsof -ti :4433 | xargs kill -9 2>/dev/null || true")
  sleep 1
  
  # Create and start server
  server = Quicsilver::Server.new(
    cert_file: cert_file,
    key_file: key_file,
    address: "127.0.0.1",
    port: 4433
  )
  
  # Set up connection callbacks
  server.on_connection do |connection_info|
    puts "🔗 New connection: #{connection_info}"
  end
  
  server.on_disconnection do |connection_info|
    puts "💔 Connection closed: #{connection_info}"  
  end
  
  puts "📋 Server Info:"
  server.server_info.each do |key, value|
    puts "   #{key}: #{value}"
  end
  puts
  
  # Start server with block (will run until interrupted)
  server.start do |srv|
    puts "🎯 Server is running! Press Ctrl+C to stop"
    puts "📡 You can now test with your client:"
    puts "   ruby examples/test_connection.rb"
    puts
    
    # Keep server running
    begin
      srv.wait_for_connections
    rescue Interrupt
      puts "\n🛑 Received interrupt signal"
    end
  end
  
rescue Quicsilver::Error => e
  puts "❌ QUIC Server Error: #{e.message}"
  puts "💡 Common issues:"
  puts "   - Certificate files invalid or missing"
  puts "   - Port already in use"
  puts "   - Insufficient permissions"
  
rescue => e
  puts "💥 Unexpected error: #{e.class} - #{e.message}"
  puts e.backtrace.first(5).join("\n") if ENV["DEBUG"]
end

puts "👋 Server stopped" 