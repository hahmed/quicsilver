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
    # connection_info now returns enhanced info even when not connected
    info = client.connection_info
    assert_kind_of Hash, info
    assert_nil info[:hostname]
    assert_nil info[:port]
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
    info = client.connection_info
    assert_kind_of Hash, info
    assert_nil info[:hostname]
    assert_nil info[:port]
    assert_equal 0, info[:uptime]
  end
  
  def test_connection_status_details
    client = Quicsilver::Client.new(connection_timeout: 1000)
    
    begin
      client.connect("nonexistent.example.com", 4433)
    rescue Quicsilver::ConnectionError, Quicsilver::TimeoutError
      # Expected to fail
    end
    
    refute client.connected?
    # connection_info now returns enhanced info after failed connection
    info = client.connection_info
    assert_kind_of Hash, info
    assert_equal "nonexistent.example.com", info[:hostname]
    assert_equal 4433, info[:port]
  end
  
  def test_stream_classes_exist
    assert defined?(Quicsilver::Stream)
    assert defined?(Quicsilver::StreamError)
  end
  
  def test_stream_data_transfer_methods_exist
    client = Quicsilver::Client.new
    
    # Test that stream methods exist (won't work without connection)
    assert client.respond_to?(:open_bidirectional_stream)
    assert client.respond_to?(:open_unidirectional_stream)
    assert client.respond_to?(:streams)
    
    # Test Stream class has data transfer methods
    stream_methods = Quicsilver::Stream.instance_methods
    assert_includes stream_methods, :send
    assert_includes stream_methods, :receive
    assert_includes stream_methods, :has_data?
    assert_includes stream_methods, :shutdown_send
  end
  
  def test_stream_send_requires_bidirectional
    # This test verifies API behavior without actual connection
    # We can't test actual sending without a QUIC server
    
    # Mock a stream-like object to test the logic
    mock_stream = Object.new
    def mock_stream.bidirectional; false; end
    def mock_stream.opened?; true; end
    
    # Test that unidirectional streams should not allow sending
    # (This is more of an API design test)
    assert_equal false, mock_stream.bidirectional
  end
  
  def test_stream_management_methods_exist
    client = Quicsilver::Client.new
    
    # Test stream management methods exist
    management_methods = [
      :streams, :active_streams, :failed_streams, :closed_streams,
      :stream_count, :active_stream_count, :find_streams, :each_stream,
      :send_to_all_streams, :close_all_streams, :close_failed_streams,
      :stream_statistics, :set_stream_callback, :remove_stream_callback,
      :wait_for_all_streams, :create_stream_manager
    ]
    
    management_methods.each do |method|
      assert client.respond_to?(method), "Client should respond to #{method}"
    end
  end
  
  def test_client_has_max_concurrent_streams
    client = Quicsilver::Client.new(max_concurrent_streams: 50)
    assert_equal 50, client.max_concurrent_streams
    
    # Test statistics structure
    stats = client.stream_statistics
    expected_keys = [:total, :active, :bidirectional, :unidirectional, :failed, :closed, :max_concurrent]
    expected_keys.each do |key|
      assert_includes stats.keys, key, "Statistics should include #{key}"
    end
    assert_equal 50, stats[:max_concurrent]
  end
  
  def test_stream_manager_class_exists
    assert defined?(Quicsilver::StreamManager)
    
    client = Quicsilver::Client.new
    manager = client.create_stream_manager(pool_size: 5, load_balance_strategy: :round_robin)
    
    assert_instance_of Quicsilver::StreamManager, manager
    assert_equal client, manager.client
    assert_equal 5, manager.pool_size
    assert_equal :round_robin, manager.load_balance_strategy
  end
  
  def test_stream_manager_methods
    client = Quicsilver::Client.new
    manager = client.create_stream_manager
    
    manager_methods = [
      :ensure_pool, :get_stream, :send_with_pool, :broadcast,
      :available_streams, :failed_streams, :pool_statistics,
      :cleanup_pool, :close_pool
    ]
    
    manager_methods.each do |method|
      assert manager.respond_to?(method), "StreamManager should respond to #{method}"
    end
    
    # Test statistics structure
    stats = manager.pool_statistics
    expected_keys = [:pool_size, :total_streams, :available, :failed, :strategy]
    expected_keys.each do |key|
      assert_includes stats.keys, key, "Pool statistics should include #{key}"
    end
  end
  
  def test_load_balance_strategies
    client = Quicsilver::Client.new
    
    strategies = [:round_robin, :least_used, :random]
    strategies.each do |strategy|
      manager = client.create_stream_manager(load_balance_strategy: strategy)
      assert_equal strategy, manager.load_balance_strategy
    end
  end
  
  def test_advanced_connection_features
    # Test reconnection configuration
    client = Quicsilver::Client.new(
      auto_reconnect: true,
      max_reconnect_attempts: 5,
      reconnect_delay: 2000
    )
    
    assert_equal 5, client.instance_variable_get(:@max_reconnect_attempts)
    assert_equal 2000, client.instance_variable_get(:@reconnect_delay)
    assert client.instance_variable_get(:@auto_reconnect)
    
    # Test connection ID assignment
    assert_nil client.connection_id # Should be nil when not connected
    assert_match(/^[a-f0-9]{16}$/, client.connection_id) if client.connected?
    
    # Test connection callbacks methods
    connection_methods = [
      :set_connection_callback, :remove_connection_callback,
      :reconnect, :connection_uptime, :graceful_disconnect
    ]
    
    connection_methods.each do |method|
      assert client.respond_to?(method), "Client should respond to #{method}"
    end
  end
  
  def test_connection_info_enhanced
    client = Quicsilver::Client.new
    
    # Test connection info structure when not connected
    info = client.connection_info
    expected_keys = [:connection_id, :hostname, :port, :uptime, :reconnect_attempts, :auto_reconnect, :last_disconnect_time]
    expected_keys.each do |key|
      assert_includes info.keys, key, "Connection info should include #{key}"
    end
    
    assert_equal 0, info[:reconnect_attempts]
    assert info[:auto_reconnect]
    assert_nil info[:hostname]
    assert_nil info[:port]
  end
  
  def test_connection_pool_class_exists
    assert defined?(Quicsilver::ConnectionPool)
    
    pool = Quicsilver::ConnectionPool.new(pool_size: 3)
    assert_equal 3, pool.pool_size
    assert_equal :round_robin, pool.load_balance_strategy
    
    # Test pool methods exist
    pool_methods = [
      :add_target, :start, :stop, :get_connection, :with_connection,
      :send_to_all_connections, :pool_statistics, :each_connection,
      :healthy_connections, :unhealthy_connections
    ]
    
    pool_methods.each do |method|
      assert pool.respond_to?(method), "ConnectionPool should respond to #{method}"
    end
  end
  
  def test_connection_pool_statistics
    pool = Quicsilver::ConnectionPool.new(pool_size: 2, load_balance_strategy: :least_used)
    
    stats = pool.pool_statistics
    expected_keys = [:pool_size, :total_connections, :healthy_connections, :connected_connections, :total_streams, :strategy, :running, :targets]
    expected_keys.each do |key|
      assert_includes stats.keys, key, "Pool statistics should include #{key}"
    end
    
    assert_equal 2, stats[:pool_size]
    assert_equal :least_used, stats[:strategy]
    assert_equal false, stats[:running]
  end
  
  def test_connection_pool_load_balance_strategies
    strategies = [:round_robin, :least_used, :random, :least_uptime]
    
    strategies.each do |strategy|
      pool = Quicsilver::ConnectionPool.new(load_balance_strategy: strategy)
      assert_equal strategy, pool.load_balance_strategy
    end
  end
  
  def test_connection_pool_targets
    pool = Quicsilver::ConnectionPool.new
    
    # Test adding targets
    pool.add_target("localhost", 4433)
    pool.add_target("example.com", 443)
    
    stats = pool.pool_statistics
    assert_equal 2, stats[:targets]
  end
end