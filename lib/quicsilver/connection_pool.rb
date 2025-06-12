# frozen_string_literal: true

module Quicsilver
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
            # Simple connectivity check
            if conn[:client].connected?
              # Try to get connection info to verify health
              info = conn[:client].connection_info
              conn[:healthy] = info && info["connected"]
            else
              conn[:healthy] = false
            end
          rescue => e
            puts "Health check failed for connection: #{e.message}"
            conn[:healthy] = false
          end
        end
        
        # Remove permanently failed connections  
        @connections.reject! { |conn| !conn[:healthy] && !conn[:client].connected? }
        
        # Ensure we maintain pool size
        ensure_pool_size
      end
    end
  end
end
