#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"

puts "🔍 Minimal QUIC Connection Debug Test"
puts "=" * 50

begin
  puts "1. Opening MSQUIC..."
  Quicsilver.open_connection
  puts "   ✅ MSQUIC opened successfully"
  
  puts "2. Creating configuration..."
  config = Quicsilver.create_configuration(true)  # unsecure
  puts "   ✅ Configuration created: #{config}"
  
  puts "3. Creating connection..."
  connection_data = Quicsilver.create_connection
  puts "   ✅ Connection created: #{connection_data}"
  
  connection_handle = connection_data[0]
  context_handle = connection_data[1]
  
  puts "4. Starting connection..."
  success = Quicsilver.start_connection(connection_handle, config, "127.0.0.1", 4433)
  puts "   ✅ Connection start result: #{success}"
  
  puts "5. Waiting for connection (timeout: 5000ms)..."
  result = Quicsilver.wait_for_connection(context_handle, 5000)
  puts "   📊 Connection result: #{result}"
  
  if result.key?("error")
    error_status = result["status"]
    error_code = result["code"]
    puts "   ❌ Connection failed with status: 0x#{error_status.to_s(16)}, code: #{error_code}"
  elsif result.key?("timeout")
    puts "   ⏰ Connection timed out"
  else
    puts "   ✅ Connection successful!"
  end

rescue => e
  puts "💥 Error: #{e.message}"
  puts "   Backtrace: #{e.backtrace.first}"
ensure
  puts "6. Cleaning up..."
  begin
    Quicsilver.close_configuration(config) if config
    Quicsilver.close_connection_handle(connection_data) if connection_data
    Quicsilver.close_connection
    puts "   ✅ Cleanup completed"
  rescue => e
    puts "   ⚠️  Cleanup error: #{e.message}"
  end
end 