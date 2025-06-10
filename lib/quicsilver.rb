# frozen_string_literal: true

require "quicsilver/version"
require "quicsilver/quicsilver"
require "securerandom"

module Quicsilver
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class StreamError < Error; end

  class ConnectionPool
    attr_reader :pool_size, :load_balance_strategy, :health_check_interval
    
    def initialize(pool_size: 5, load_balance_strategy: :round_robin, health_check_interval: 30, **client_options)
      @pool_size = pool_size
      @load_balance_strategy = load_balance_strategy
      @health_check_interval = health_check_interval
      @client_options = client_options
      @connections = []
      @round_robin_index = 0
      @mutex = Mutex.new
      @health_check_thread = nil
      @running = false
      @targets = []
    end
    
    def add_target(hostname, port = 4433)
      @targets << { hostname: hostname, port: port }
    end
    
    def start
      @mutex.synchronize do
        return if @running
        @running = true
        
        # Create initial connections
        ensure_pool_size
        
        # Start health check thread
        start_health_check if @health_check_interval > 0
      end
    end
    
    def stop
      @mutex.synchronize do
        return unless @running
        @running = false
        
        # Stop health check
        @health_check_thread&.kill
        @health_check_thread = nil
        
        # Close all connections
        @connections.each do |conn|
          begin
            conn[:client].disconnect
          rescue => e
            puts "Error disconnecting client: #{e.message}"
          end
        end
        @connections.clear
      end
    end
    
    def get_connection
      @mutex.synchronize do
        ensure_pool_size if @running
        
        healthy_connections = @connections.select { |conn| conn[:healthy] && conn[:client].connected? }
        return nil if healthy_connections.empty?
        
        case @load_balance_strategy
        when :round_robin
          conn = healthy_connections[@round_robin_index % healthy_connections.size]
          @round_robin_index += 1
          conn[:client]
        when :least_used
          # Find connection with fewest active streams
          conn = healthy_connections.min_by { |c| c[:client].active_stream_count }
          conn[:client]
        when :random
          conn = healthy_connections.sample
          conn[:client]
        when :least_uptime
          # Prefer newer connections
          conn = healthy_connections.min_by { |c| c[:client].connection_uptime }
          conn[:client]
        else
          conn = healthy_connections.first
          conn[:client]
        end
      end
    end
    
    def with_connection(&block)
      client = get_connection
      return nil unless client
      
      begin
        yield client
      rescue Error => e
        # Mark connection as unhealthy on errors
        mark_connection_unhealthy(client)
        raise e
      end
    end
    
    def send_to_all_connections(data)
      sent_count = 0
      @connections.each do |conn|
        if conn[:healthy] && conn[:client].connected?
          begin
            conn[:client].send_to_all_streams(data)
            sent_count += 1
          rescue Error => e
            puts "Failed to send to connection: #{e.message}"
            mark_connection_unhealthy(conn[:client])
          end
        end
      end
      sent_count
    end
    
    def pool_statistics
      @mutex.synchronize do
        healthy_count = @connections.count { |conn| conn[:healthy] }
        connected_count = @connections.count { |conn| conn[:client].connected? }
        total_streams = @connections.sum { |conn| conn[:client].stream_count }
        
        {
          pool_size: @pool_size,
          total_connections: @connections.size,
          healthy_connections: healthy_count,
          connected_connections: connected_count,
          total_streams: total_streams,
          strategy: @load_balance_strategy,
          running: @running,
          targets: @targets.size
        }
      end
    end
    
    def each_connection(&block)
      @connections.each { |conn| yield conn[:client] }
    end
    
    def healthy_connections
      @connections.select { |conn| conn[:healthy] }.map { |conn| conn[:client] }
    end
    
    def unhealthy_connections
      @connections.select { |conn| !conn[:healthy] }.map { |conn| conn[:client] }
    end
    
    private
    
    def ensure_pool_size
      return if @targets.empty?
      
      # Remove disconnected/failed connections
      @connections.reject! do |conn|
        if !conn[:client].connected? && !conn[:client].connection_data
          true
        else
          false
        end
      end
      
      # Add connections up to pool size
      while @connections.size < @pool_size && @targets.any?
        target = @targets[@connections.size % @targets.size]
        
        begin
          client = Client.new(@client_options)
          client.connect(target[:hostname], target[:port])
          
          @connections << {
            client: client,
            healthy: true,
            created_at: Time.now,
            target: target
          }
        rescue Error => e
          puts "Failed to create connection to #{target[:hostname]}:#{target[:port]}: #{e.message}"
          # Continue trying to fill pool with other targets
        end
      end
    end
    
    def mark_connection_unhealthy(client)
      @mutex.synchronize do
        conn = @connections.find { |c| c[:client] == client }
        conn[:healthy] = false if conn
      end
    end
    
    def start_health_check
      @health_check_thread = Thread.new do
        while @running
          sleep(@health_check_interval)
          perform_health_check if @running
        end
      end
    end
    
    def perform_health_check
      @mutex.synchronize do
        @connections.each do |conn|
          begin
            # Check if connection is still alive
            if conn[:client].connected?
              conn[:healthy] = true
            else
              conn[:healthy] = false
              # Try to reconnect unhealthy connections
              if conn[:client].instance_variable_get(:@auto_reconnect)
                Thread.new do
                  begin
                    conn[:client].reconnect
                    conn[:healthy] = true
                  rescue Error => e
                    puts "Health check reconnection failed: #{e.message}"
                  end
                end
              end
            end
          rescue => e
            conn[:healthy] = false
            puts "Health check failed for connection: #{e.message}"
          end
        end
      end
    end
  end

  class StreamManager
    attr_reader :client, :pool_size, :load_balance_strategy
    
    def initialize(client, pool_size: 10, load_balance_strategy: :round_robin)
      @client = client
      @pool_size = pool_size
      @load_balance_strategy = load_balance_strategy
      @stream_pool = []
      @round_robin_index = 0
      @mutex = Mutex.new
    end
    
    def ensure_pool
      @mutex.synchronize do
        needed = @pool_size - available_streams.size
        needed.times do
          begin
            stream = @client.open_bidirectional_stream
            @stream_pool << stream
          rescue Error => e
            puts "Failed to create stream for pool: #{e.message}"
            break
          end
        end
      end
    end
    
    def get_stream
      @mutex.synchronize do
        ensure_pool
        
        available = available_streams
        return nil if available.empty?
        
        case @load_balance_strategy
        when :round_robin
          stream = available[@round_robin_index % available.size]
          @round_robin_index += 1
          stream
        when :least_used
          # For now, just return first available
          # Could track usage per stream in future
          available.first
        when :random
          available.sample
        else
          available.first
        end
      end
    end
    
    def send_with_pool(data)
      stream = get_stream
      return false unless stream
      
      begin
        stream.send(data)
        true
      rescue Error => e
        puts "Failed to send with pooled stream: #{e.message}"
        false
      end
    end
    
    def broadcast(data)
      sent_count = 0
      @stream_pool.each do |stream|
        if stream.opened?
          begin
            stream.send(data)
            sent_count += 1
          rescue Error => e
            puts "Failed to broadcast to stream: #{e.message}"
          end
        end
      end
      sent_count
    end
    
    def available_streams
      @stream_pool.select(&:opened?)
    end
    
    def failed_streams
      @stream_pool.select(&:failed?)
    end
    
    def pool_statistics
      {
        pool_size: @pool_size,
        total_streams: @stream_pool.size,
        available: available_streams.size,
        failed: failed_streams.size,
        strategy: @load_balance_strategy
      }
    end
    
    def cleanup_pool
      @mutex.synchronize do
        @stream_pool.reject! { |stream| stream.closed? || stream.failed? }
      end
    end
    
    def close_pool
      @mutex.synchronize do
        @stream_pool.each(&:close)
        @stream_pool.clear
      end
    end
  end

  class Stream
    attr_reader :bidirectional, :client
    
    def initialize(client, bidirectional: true, stream_timeout: 5000)
      @client = client
      @bidirectional = bidirectional
      @stream_timeout = stream_timeout
      @stream_data = nil
      @opened = false
      
      raise Error, "Client must be connected" unless client.connected?
      
      # Create the stream using the connection handle
      connection_handle = client.connection_data[0]
      @stream_data = Quicsilver.create_stream(connection_handle, bidirectional)
      
      # Wait for stream to open
      wait_for_open
      @opened = true
    end
    
    def opened?
      return false unless @stream_data
      
      context_handle = @stream_data[1]
      status = Quicsilver.stream_status(context_handle)
      status["opened"] && !status["failed"]
    end
    
    def closed?
      return true unless @stream_data
      
      context_handle = @stream_data[1]  
      status = Quicsilver.stream_status(context_handle)
      status["closed"]
    end
    
    def failed?
      return false unless @stream_data
      
      context_handle = @stream_data[1]
      status = Quicsilver.stream_status(context_handle)
      status["failed"]
    end
    
    def status
      return nil unless @stream_data
      
      context_handle = @stream_data[1]
      Quicsilver.stream_status(context_handle)
    end
    
    def send(data)
      raise Error, "Stream not opened" unless opened?
      raise Error, "Cannot send on unidirectional stream" unless @bidirectional
      
      data = data.to_s unless data.is_a?(String)
      return true if data.empty?
      
      stream_handle = @stream_data[0]
      result = Quicsilver.stream_send(stream_handle, data)
      
      unless result
        raise Error, "Failed to send data on stream"
      end
      
      result
    end
    
    def receive(timeout: 1000)
      raise Error, "Stream not opened" unless opened?
      
      context_handle = @stream_data[1]
      
      # Wait for data with timeout
      elapsed = 0
      sleep_interval = 0.01 # 10ms
      
      while elapsed < timeout && !has_data?
        sleep(sleep_interval)
        elapsed += (sleep_interval * 1000)
        
        # Check if stream failed or closed
        break if failed? || closed?
      end
      
      # Get received data
      Quicsilver.stream_receive(context_handle)
    end
    
    def has_data?
      return false unless @stream_data
      
      context_handle = @stream_data[1]
      Quicsilver.stream_has_data(context_handle)
    end
    
    def shutdown_send
      return unless @stream_data
      
      stream_handle = @stream_data[0]
      Quicsilver.stream_shutdown_send(stream_handle)
    end
    
    def close
      return unless @stream_data
      
      Quicsilver.close_stream(@stream_data)
      @stream_data = nil
      @opened = false
    end
    
    private
    
    def wait_for_open
      return unless @stream_data
      
      context_handle = @stream_data[1]
      timeout = @stream_timeout
      elapsed = 0
      sleep_interval = 0.01 # 10ms
      
      while elapsed < timeout && !opened? && !failed?
        sleep(sleep_interval)
        elapsed += (sleep_interval * 1000)
      end
      
      if failed?
        close
        raise StreamError, "Stream failed to open"
      elsif !opened?
        close
        raise TimeoutError, "Stream timed out after #{timeout}ms"
      end
    end
  end

  class Client
    attr_reader :connection_data, :max_concurrent_streams, :hostname, :port, :reconnect_attempts, :connection_id
    
    def initialize(unsecure: true, connection_timeout: 5000, max_concurrent_streams: 100, auto_reconnect: true, max_reconnect_attempts: 3, reconnect_delay: 1000)
      @unsecure = unsecure
      @connection_timeout = connection_timeout
      @max_concurrent_streams = max_concurrent_streams
      @auto_reconnect = auto_reconnect
      @max_reconnect_attempts = max_reconnect_attempts
      @reconnect_delay = reconnect_delay
      @config = nil
      @connection_data = nil
      @connected = false
      @streams = []
      @stream_callbacks = {}
      @connection_callbacks = {}
      @hostname = nil
      @port = nil
      @reconnect_attempts = 0
      @connection_id = SecureRandom.hex(8)
      @last_disconnect_time = nil
      @connection_start_time = nil
      
      # Initialize MSQUIC if not already done
      Quicsilver.open_connection
    end
    
    def connect(hostname, port = 4433)
      @hostname = hostname
      @port = port
      
      attempt_connection
    end
    
    def reconnect
      raise Error, "Cannot reconnect - no previous connection info" unless @hostname && @port
      
      disconnect if @connected
      @reconnect_attempts += 1
      
      if @reconnect_attempts > @max_reconnect_attempts
        trigger_connection_callback(:max_reconnect_attempts_reached, @reconnect_attempts)
        raise ConnectionError, "Maximum reconnection attempts (#{@max_reconnect_attempts}) exceeded"
      end
      
      trigger_connection_callback(:reconnecting, @reconnect_attempts)
      
      # Exponential backoff
      delay = @reconnect_delay * (2 ** (@reconnect_attempts - 1))
      sleep(delay / 1000.0) if delay > 0
      
      attempt_connection
    end
    
    def connection_uptime
      return 0 unless @connection_start_time
      Time.now - @connection_start_time
    end
    
    def connection_info
      base_info = if @connection_data
        context_handle = @connection_data[1]
        Quicsilver.connection_status(context_handle)
      else
        {}
      end
      
      base_info.merge({
        connection_id: @connection_id,
        hostname: @hostname,
        port: @port,
        uptime: connection_uptime,
        reconnect_attempts: @reconnect_attempts,
        auto_reconnect: @auto_reconnect,
        last_disconnect_time: @last_disconnect_time
      })
    end
    
    def set_connection_callback(event, &block)
      @connection_callbacks[event] = block
    end
    
    def remove_connection_callback(event)
      @connection_callbacks.delete(event)
    end
    
    def graceful_disconnect(timeout: 5000)
      return unless @connected
      
      trigger_connection_callback(:disconnecting, "graceful")
      
      # Close all streams gracefully
      close_all_streams
      
      # Wait for streams to close
      wait_for_all_streams(timeout: timeout)
      
      # Disconnect
      disconnect
    end
    
    def open_bidirectional_stream(**options)
      ensure_connected
      check_stream_limit
      
      stream = Stream.new(self, bidirectional: true, **options)
      add_stream(stream)
      stream
    end
    
    def open_unidirectional_stream(**options) 
      ensure_connected
      check_stream_limit
      
      stream = Stream.new(self, bidirectional: false, **options)
      add_stream(stream)
      stream
    end
    
    def open_stream(bidirectional: true, **options)
      if bidirectional
        open_bidirectional_stream(**options)
      else
        open_unidirectional_stream(**options)
      end
    end
    
    def streams
      cleanup_closed_streams
      @streams.dup
    end
    
    def active_streams
      cleanup_closed_streams
      @streams.select(&:opened?)
    end
    
    def failed_streams
      @streams.select(&:failed?)
    end
    
    def closed_streams
      @streams.select(&:closed?)
    end
    
    def stream_count
      cleanup_closed_streams
      @streams.size
    end
    
    def active_stream_count
      active_streams.size
    end
    
    def find_streams(&block)
      cleanup_closed_streams
      @streams.select(&block)
    end
    
    def each_stream(&block)
      cleanup_closed_streams
      @streams.each(&block)
    end
    
    def send_to_all_streams(data)
      ensure_connected
      sent_count = 0
      each_stream do |stream|
        if stream.opened? && stream.bidirectional
          begin
            stream.send(data)
            sent_count += 1
          rescue Error => e
            # Log error but continue with other streams
            puts "Failed to send to stream: #{e.message}"
          end
        end
      end
      sent_count
    end
    
    def close_all_streams
      @streams.dup.each do |stream|
        begin
          stream.close
        rescue Error => e
          # Continue closing other streams even if one fails
          puts "Error closing stream: #{e.message}"
        end
      end
      @streams.clear
    end
    
    def close_failed_streams
      failed_streams.each(&:close)
      cleanup_closed_streams
    end
    
    def stream_statistics
      cleanup_closed_streams
      {
        total: @streams.size,
        active: active_stream_count,
        bidirectional: @streams.count(&:bidirectional),
        unidirectional: @streams.count { |s| !s.bidirectional },
        failed: failed_streams.size,
        closed: closed_streams.size,
        max_concurrent: @max_concurrent_streams
      }
    end
    
    def set_stream_callback(event, &block)
      @stream_callbacks[event] = block
    end
    
    def remove_stream_callback(event)
      @stream_callbacks.delete(event)
    end
    
    def wait_for_all_streams(timeout: 5000)
      start_time = Time.now
      
      while (Time.now - start_time) * 1000 < timeout
        active = active_streams
        return true if active.empty?
        
        sleep(0.01) # 10ms
      end
      
      false # Timeout
    end
    
    def create_stream_manager(**options)
      StreamManager.new(self, **options)
    end
    
    def disconnect
      return unless @connected || @connection_data
      
      trigger_connection_callback(:disconnecting, "forced")
      @last_disconnect_time = Time.now
      
      # Close all streams first
      close_all_streams
      
      # Close connection (in reverse order of creation)
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      Quicsilver.close_configuration(@config) if @config
      
      @connection_data = nil
      @config = nil
      @connected = false
      @connection_start_time = nil
      
      trigger_connection_callback(:disconnected)
      puts "Disconnected" if @connected
    end
    
    def connected?
      return false unless @connected && @connection_data
      
      begin
        # Check actual connection status
        context_handle = @connection_data[1]
        status = Quicsilver.connection_status(context_handle)
        
        was_connected = @connected
        @connected = status["connected"] && !status["failed"]
        
        # Handle automatic reconnection if connection was lost
        if was_connected && !@connected && @auto_reconnect
          trigger_connection_callback(:connection_lost)
          Thread.new { handle_auto_reconnect }
        end
        
        @connected
      rescue => e
        @connected = false
        if @auto_reconnect
          Thread.new { handle_auto_reconnect }
        end
        false
      end
    end
    
    # Auto-cleanup when object is garbage collected
    def finalize
      disconnect
    end
    
    private
    
    def attempt_connection
      raise Error, "Already connected" if @connected
      
      trigger_connection_callback(:connecting, { hostname: @hostname, port: @port, attempt: @reconnect_attempts + 1 })
      
      # Create configuration
      @config = Quicsilver.create_configuration(@unsecure)
      raise Error, "Failed to create configuration" if @config.nil?
      
      # Create connection (returns [handle, context])
      @connection_data = Quicsilver.create_connection
      raise Error, "Failed to create connection" if @connection_data.nil?
      
      connection_handle = @connection_data[0]
      context_handle = @connection_data[1]
      
      # Start the connection
      success = Quicsilver.start_connection(connection_handle, @config, @hostname, @port)
      raise Error, "Failed to start connection" unless success
      
      # Wait for connection to establish or fail
      result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)
      
      if result.key?("error")
        error_status = result["status"]
        error_code = result["code"]
        cleanup_failed_connection
        error_msg = "Connection failed with status: 0x#{error_status.to_s(16)}, code: #{error_code}"
        trigger_connection_callback(:connection_failed, error_msg)
        raise ConnectionError, error_msg
      elsif result.key?("timeout")
        cleanup_failed_connection
        error_msg = "Connection timed out after #{@connection_timeout}ms"
        trigger_connection_callback(:connection_timeout, error_msg)
        raise TimeoutError, error_msg
      end
      
      @connected = true
      @connection_start_time = Time.now
      @reconnect_attempts = 0 # Reset on successful connection
      
      trigger_connection_callback(:connected, { hostname: @hostname, port: @port })
      puts "Connected to #{@hostname}:#{@port}"
      true
    end
    
    def cleanup_failed_connection
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      Quicsilver.close_configuration(@config) if @config
      @connection_data = nil
      @config = nil
      @connected = false
    end
    
    def ensure_connected
      return if connected?
      
      if @auto_reconnect && @hostname && @port
        reconnect
      else
        raise Error, "Not connected"
      end
    end
    
    def handle_auto_reconnect
      return unless @auto_reconnect
      
      begin
        reconnect
      rescue Error => e
        trigger_connection_callback(:reconnect_failed, e.message)
        puts "Auto-reconnect failed: #{e.message}"
      end
    end
    
    def add_stream(stream)
      @streams << stream
      trigger_callback(:stream_opened, stream)
    end
    
    def check_stream_limit
      cleanup_closed_streams
      if @streams.size >= @max_concurrent_streams
        raise Error, "Maximum concurrent streams (#{@max_concurrent_streams}) exceeded"
      end
    end
    
    def cleanup_closed_streams
      before_count = @streams.size
      @streams.reject! do |stream|
        if stream.closed? || stream.failed?
          trigger_callback(:stream_closed, stream) if stream.closed?
          trigger_callback(:stream_failed, stream) if stream.failed?
          true
        else
          false
        end
      end
      
      cleaned_count = before_count - @streams.size
      trigger_callback(:streams_cleaned, cleaned_count) if cleaned_count > 0
    end
    
    def trigger_callback(event, *args)
      callback = @stream_callbacks[event]
      callback.call(*args) if callback
    end
    
    def trigger_connection_callback(event, *args)
      callback = @connection_callbacks[event]
      callback.call(*args) if callback
    end
  end
  
  def self.connect(hostname, port = 4433, unsecure: true, **options)
    client = Client.new(unsecure: unsecure, **options)
    client.connect(hostname, port)
    
    if block_given?
      begin
        yield client
      ensure
        client.disconnect
      end
    else
      client
    end
  end
end