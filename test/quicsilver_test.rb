require "test_helper"
require "quicsilver"

class QuicsilverTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Quicsilver::VERSION
  end

  def test_open_close
    handle = Quicsilver.open_connection
    assert handle
    Quicsilver.close_connection
  end
  
  def test_client_creation
    client = Quicsilver::Client.new
    refute client.connected?
    assert_nil client.connection_info
    assert_empty client.streams
  end
  
  def test_stream_creation_requires_connection
    client = Quicsilver::Client.new
    
    assert_raises(Quicsilver::Error) do
      client.open_bidirectional_stream
    end
    
    assert_raises(Quicsilver::Error) do 
      client.open_unidirectional_stream
    end
    
    assert_raises(Quicsilver::Error) do
      client.open_stream
    end
  end
  
  def test_connection_failure_on_invalid_host
    client = Quicsilver::Client.new(connection_timeout: 2000)
    
    # MSQUIC usually detects invalid hostnames as connection failures quickly
    error_raised = false
    begin
      client.connect("nonexistent.example.com", 4433)
    rescue Quicsilver::ConnectionError
      error_raised = true
    rescue Quicsilver::TimeoutError
      error_raised = true
    end
    
    assert error_raised, "Expected either ConnectionError or TimeoutError"
    refute client.connected?
  end
  
  def test_connection_failure_on_unreachable_host
    client = Quicsilver::Client.new(connection_timeout: 2000)
    
    # MSQUIC usually detects unreachable hosts as connection failures
    error_raised = false
    begin
      client.connect("192.0.2.1", 4433) # RFC 5737 test network
    rescue Quicsilver::ConnectionError
      error_raised = true
    rescue Quicsilver::TimeoutError
      error_raised = true
    end
    
    assert error_raised, "Expected either ConnectionError or TimeoutError"
    refute client.connected?
  end
  
  def test_client_block_form
    connection_attempted = false
    error_raised = false
    
    begin
      Quicsilver.connect("nonexistent.example.com", 4433, connection_timeout: 1000) do |client|
        connection_attempted = true
        refute client.connected?
      end
    rescue Quicsilver::ConnectionError, Quicsilver::TimeoutError
      error_raised = true
    end
    
    assert error_raised, "Expected connection to fail"
    # Block form should not execute the block if connection fails
    refute connection_attempted
  end
  
  def test_connection_info_when_not_connected
    client = Quicsilver::Client.new
    assert_nil client.connection_info
  end
  
  def test_connection_status_details
    client = Quicsilver::Client.new(connection_timeout: 1000)
    
    begin
      client.connect("nonexistent.example.com", 4433)
    rescue Quicsilver::ConnectionError, Quicsilver::TimeoutError
      # Expected to fail
    end
    
    refute client.connected?
    # connection_info should be nil after failed connection cleanup
    assert_nil client.connection_info
  end
  
  def test_stream_classes_exist
    assert defined?(Quicsilver::Stream)
    assert defined?(Quicsilver::StreamError)
  end
end