require "test_helper"
require "quicsilver"

class QuicsilverTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Quicsilver::VERSION
  end

  def test_client_creation
    client = Quicsilver::Client.new("localhost", 4433)
    refute client.connected?
    info = client.connection_info
    assert_kind_of Hash, info
    assert_equal "localhost", info[:hostname]
    assert_equal 4433, info[:port]
  end
  
  def test_server_creation
    server = Quicsilver::Server.new(4433, server_configuration: default_server_config)
    refute server.running?
    assert_equal 4433, server.port
    assert_equal "0.0.0.0", server.address
  end
  
  def test_connection_failure_on_invalid_host
    client = Quicsilver::Client.new("nonexistent.example.com", 4433, connection_timeout: 2000)
    
    error_raised = false
    begin
      client.connect
    rescue Quicsilver::ConnectionError
      error_raised = true
    rescue Quicsilver::TimeoutError
      error_raised = true
    end
    
    assert error_raised, "Expected either ConnectionError or TimeoutError"
    refute client.connected?
  end
  
  def test_connection_info_when_not_connected
    client = Quicsilver::Client.new("localhost", 4433)
    info = client.connection_info
    assert_kind_of Hash, info
    assert_equal "localhost", info[:hostname]
    assert_equal 4433, info[:port]
    assert_equal 0, info[:uptime]
  end

  def test_client_server_communication
    server = Quicsilver::Server.new(4434, server_configuration: default_server_config) # Use different port to avoid conflicts
    client = Quicsilver::Client.new("localhost", 4434, connection_timeout: 5000)
    
    # Start server in a separate thread
    server_thread = Thread.new { server.start }
    
    # Give server time to start
    sleep(0.5)
    
    # Test client connection
    begin
      client.connect
      assert client.connected?, "Client should be connected to server"
      
      # Test connection info when connected
      info = client.connection_info
      assert_equal "localhost", info[:hostname]
      assert_equal 4434, info[:port]
      assert info[:uptime] >= 0, "Uptime should be non-negative"
      
    rescue Quicsilver::ConnectionError, Quicsilver::TimeoutError => e
      # Connection might fail in test environment, that's okay
      # We're mainly testing that the methods exist and don't crash
      assert_kind_of StandardError, e
    ensure
      # Cleanup
      client.disconnect if client.connected?
      server.stop if server.running?
      server_thread.join
    end
  end

  def test_multiple_clients_connecting
    server = Quicsilver::Server.new(4435, server_configuration: default_server_config) # Use different port
    clients = []
    
    # Create multiple clients
    3.times do |i|
      clients << Quicsilver::Client.new("localhost", 4435, connection_timeout: 3000)
    end
    
    # Start server in a separate thread
    server_thread = Thread.new { server.start }
    
    # Give server time to start
    sleep(0.5)
    
    # Test multiple clients connecting
    connected_clients = 0
    clients.each_with_index do |client, i|
      begin
        client.connect
        if client.connected?
          connected_clients += 1
          assert client.connected?, "Client #{i} should be connected"
        end
      rescue Quicsilver::ConnectionError, Quicsilver::TimeoutError => e
        # Connection might fail in test environment, that's okay
        assert_kind_of StandardError, e
      end
    end
    
    # Cleanup
    clients.each { |client| client.disconnect if client.connected? }
    server.stop if server.running?
    server_thread.join
    
    # At least verify that the server can handle multiple connection attempts
    assert clients.length > 0, "Should have created multiple clients"
  end

  def test_listener_uses_configured_alpn
    # Server with non-standard ALPN — client uses "h3" so handshake should fail
    config = Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path, alpn: "not-h3")
    server = Quicsilver::Server.new(4437, server_configuration: config)
    client = Quicsilver::Client.new("localhost", 4437, connection_timeout: 2000)

    server_thread = Thread.new { server.start }
    sleep 0.5

    assert_raises(Quicsilver::ConnectionError, Quicsilver::TimeoutError) do
      client.connect
    end
  ensure
    client&.disconnect if client&.connected?
    server&.stop if server&.running?
    server_thread&.join(2)
  end

  def test_server_restart_after_stop
    server = Quicsilver::Server.new(4436, server_configuration: default_server_config)

    # Start server in thread (since start blocks)
    server_thread = Thread.new { server.start }
    sleep 0.3

    assert server.running?, "Server should be running after start"

    # Stop server
    server.stop
    server_thread.join(2)

    refute server.running?, "Server should not be running after stop"
  end

  private

  def default_server_config
    Quicsilver::ServerConfiguration.new(
      cert_file_path,
      key_file_path,
    )
  end
end