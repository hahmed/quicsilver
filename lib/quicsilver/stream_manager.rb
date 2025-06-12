# frozen_string_literal: true

module Quicsilver
  class StreamManager
    attr_reader :pool_size, :load_balance_strategy
    
    def initialize(client, pool_size: 10, load_balance_strategy: :round_robin)
      @client = client
      @pool_size = pool_size
      @load_balance_strategy = load_balance_strategy
      @stream_pool = []
      @round_robin_index = 0
      @mutex = Mutex.new
    end
    
    def client
      @client
    end
    
    def ensure_pool
      @mutex.synchronize do
        # Remove closed/failed streams from pool
        @stream_pool.reject! { |stream| stream.closed? || stream.failed? }
        
        # Add new streams if needed
        while @stream_pool.size < @pool_size
          stream = @client.open_bidirectional_stream
          @stream_pool << stream if stream
        end
      end
    end
    
    def get_stream
      @mutex.synchronize do
        ensure_pool
        
        available = @stream_pool.select(&:opened?)
        return nil if available.empty?
        
        case @load_balance_strategy
        when :round_robin
          stream = available[@round_robin_index % available.size]
          @round_robin_index += 1
          stream
        when :least_used
          # For now, just return first available
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
      raise Error, "No available streams in pool" unless stream
      
      begin
        stream.send(data)
      rescue Error => e
        # Remove failed stream from pool
        @mutex.synchronize { @stream_pool.delete(stream) }
        raise e
      end
    end
    
    def broadcast(data)
      sent_count = 0
      @stream_pool.dup.each do |stream|
        if stream.opened?
          begin
            stream.send(data)
            sent_count += 1
          rescue Error => e
            puts "Failed to send to stream: #{e.message}"
            @mutex.synchronize { @stream_pool.delete(stream) }
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
        available_streams: available_streams.size,
        failed: failed_streams.size,
        failed_streams: failed_streams.size,
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
end
