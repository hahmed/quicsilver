#!/usr/bin/env ruby

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quicsilver"

def test_quic_connection(host = "127.0.0.1", port = 4433)
  puts "🔗 Testing QUIC Connection to #{host}:#{port}..."
  puts

  begin
    start_time = Time.now
    
    Quicsilver.connect(host, port, 
                       unsecure: true, 
                       connection_timeout: 5000) do |client|
      
      end_time = Time.now
      connection_time = ((end_time - start_time) * 1000).round(1)
      
      puts "✅ SUCCESS! Connected to QUIC server"
      puts "   🕐 Connection time: #{connection_time}ms"
      puts "   📊 Connected status: #{client.connected?}"
      puts "   📋 Connection info: #{client.connection_info}"
      puts
      
      puts "🧪 Testing connection stability..."
      3.times do |i|
        sleep(1)
        status = client.connected?
        puts "   ⏱️  Tick #{i+1}: Connected = #{status}"
        break unless status
      end
      
      puts "✅ Connection test completed!"
    end
    
    puts "🔒 Connection closed cleanly"
    return true
    
  rescue Quicsilver::ConnectionError => e
    puts "❌ Connection failed: #{e.message}"
    puts "💡 Make sure a QUIC server is running on #{host}:#{port}"
    puts "💡 Server must support 'quicsilver' ALPN protocol"
    return false
    
  rescue Quicsilver::TimeoutError => e
    puts "⏰ Connection timed out: #{e.message}"
    puts "💡 The server might be slow or not responding"
    return false
    
  rescue => e
    puts "💥 Unexpected error: #{e.class} - #{e.message}"
    return false
  end
end

def show_help
  puts "🚀 QUIC Connection Test Script"
  puts "=============================="
  puts
  puts "Usage:"
  puts "  ruby #{File.basename(__FILE__)}                    # Test localhost:4433"
  puts "  ruby #{File.basename(__FILE__)} <host> <port>      # Test custom host/port"
  puts "  ruby #{File.basename(__FILE__)} --help             # Show this help"
  puts
  puts "Before running, make sure you have a QUIC server running."
  puts "See examples/README.md for server setup options."
  puts
end

if __FILE__ == $0
  if ARGV.include?("--help") || ARGV.include?("-h")
    show_help
  elsif ARGV.length == 2
    host, port = ARGV[0], ARGV[1].to_i
    success = test_quic_connection(host, port)
    exit(success ? 0 : 1)
  elsif ARGV.length == 0
    success = test_quic_connection
    exit(success ? 0 : 1)
  else
    puts "❌ Invalid arguments. Use --help for usage information."
    exit(1)
  end
end 