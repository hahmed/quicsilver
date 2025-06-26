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
    server = Quicsilver::Server.new(4433)
    refute server.running?
    info = server.server_info
    assert_kind_of Hash, info
    assert_equal 4433, info[:port]
    assert_equal "0.0.0.0", info[:address]
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
end