# frozen_string_literal: true

module Quicsilver
  class Client
    attr_reader :connection_data, :hostname, :port, :unsecure, :connection_timeout, :max_concurrent_streams, :auto_reconnect, :max_reconnect_attempts, :reconnect_delay
    
    def initialize(unsecure: false, connection_timeout: 5000, max_concurrent_streams: 100, auto_reconnect: true, max_reconnect_attempts: 3, reconnect_delay: 1000)
      @unsecure = unsecure
      @connection_timeout = connection_timeout
      @max_concurrent_streams = max_concurrent_streams
      @auto_reconnect = auto_reconnect
      @max_reconnect_attempts = max_reconnect_attempts
      @reconnect_delay = reconnect_delay
      
      @connection_data = nil
      @connected = false
      @streams = []
      @hostname = nil
      @port = nil
      @connection_start_time = nil
      @reconnect_attempts = 0
      @last_disconnect_time = nil
      
      @connection_callbacks = {}
      @stream_callbacks = {}
      
      ObjectSpace.define_finalizer(self, self.class.finalize_proc(@connection_data))
    end
    
    def connect(hostname, port = 4433)
      @hostname = hostname
      @port = port
      
      attempt_connection
    end
    
    def reconnect
      raise Error, "Cannot reconnect - no previous connection info" unless @hostname && @port
      
      if @connected
        disconnect
        sleep(@reconnect_delay / 1000.0)
      end
      
      @reconnect_attempts += 1
      
      begin
        attempt_connection
        @reconnect_attempts = 0 # Reset on successful connection
        trigger_connection_callback(:reconnected, connection_info)
      rescue Error => e
        @last_disconnect_time = Time.now
        trigger_connection_callback(:reconnect_failed, { 
          attempt: @reconnect_attempts, 
          error: e.message,
          hostname: @hostname,
          port: @port
        })
        
        if @reconnect_attempts >= @max_reconnect_attempts
          trigger_connection_callback(:max_reconnect_attempts_reached, { 
            attempts: @reconnect_attempts,
            hostname: @hostname,
            port: @port
          })
          raise e
        end
        
        handle_auto_reconnect
        raise e
      end
    end
    
    def connection_uptime
      return 0 unless @connection_start_time
      Time.now - @connection_start_time
    end
    
    def connection_id
      return nil unless @connection_data
      SecureRandom.hex(8)
    end
    
    def connection_info
      base_info = if @connection_data
        begin
          context_handle = @connection_data[1]
          Quicsilver.connection_status(context_handle) || {}
        rescue => e
          {}
        end
      else
        {}
      end
      
      base_info.merge({
        connection_id: connection_id,
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
      
      # Close all streams first
      close_all_streams
      
      # Wait for streams to close
      start_time = Time.now
      while active_streams.any? && (Time.now - start_time) < (timeout / 1000.0)
        sleep(0.1)
      end
      
      # Force close remaining streams
      close_all_streams if active_streams.any?
      
      # Disconnect
      disconnect
    end
    
    def open_bidirectional_stream(**options)
      ensure_connected
      check_stream_limit
      
      stream = Stream.new(self, bidirectional: true, **options)
      stream.opened? ? stream : nil
    end
    
    def open_unidirectional_stream(**options) 
      ensure_connected
      check_stream_limit
      
      stream = Stream.new(self, bidirectional: false, **options)
      stream.opened? ? stream : nil
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
      error_count = 0
      
      active_streams.each do |stream|
        begin
          stream.send(data)
          sent_count += 1
        rescue Error => e
          error_count += 1
          trigger_callback(:stream_send_failed, stream, e)
        end
      end
      
      {
        sent: sent_count,
        errors: error_count,
        total_streams: active_streams.size
      }
    end
    
    def close_all_streams
      @streams.dup.each do |stream|
        begin
          stream.close
        rescue => e
          # Ignore errors during cleanup
        end
      end
      cleanup_closed_streams
    end
    
    def close_failed_streams
      failed_streams.each(&:close)
      cleanup_closed_streams
    end
    
    def stream_statistics
      cleanup_closed_streams
      
      {
        total: @streams.size,
        active: active_streams.size,
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
      
      while active_streams.any? && (Time.now - start_time) < (timeout / 1000.0)
        sleep(0.1)
      end
      
      active_streams.empty?
    end
    
    def create_stream_manager(**options)
      StreamManager.new(self, **options)
    end
    
    def disconnect
      return unless @connected || @connection_data
      
      @last_disconnect_time = Time.now
      
      begin
        # Close all streams first
        close_all_streams
        
        # Close connection
        if @connection_data
          Quicsilver.disconnect_handle(@connection_data)
          trigger_connection_callback(:disconnected, connection_info)
        end
      rescue => e
        trigger_connection_callback(:disconnect_error, { error: e.message })
      ensure
        cleanup_failed_connection
        @connected = false
        @connection_start_time = nil
      end
    end
    
    def connected?
      return false unless @connected && @connection_data
      
      begin
        # Get connection status from the C extension
        context_handle = @connection_data[1]
        info = Quicsilver.connection_status(context_handle)
        if info && info.key?("connected")
          is_connected = info["connected"] && !info["failed"]
          
          # If C extension says we're disconnected, update our state
          if !is_connected && @connected
            @connected = false
            @last_disconnect_time = Time.now
            trigger_connection_callback(:connection_lost, connection_info)
            
            # Attempt auto-reconnect if enabled
            handle_auto_reconnect if @auto_reconnect
          end
          
          is_connected
        else
          # If we can't get status, assume disconnected
          if @connected
            @connected = false
            @last_disconnect_time = Time.now
            trigger_connection_callback(:connection_lost, connection_info)
            handle_auto_reconnect if @auto_reconnect
          end
          false
        end
      rescue => e
        # If there's an error checking status, assume disconnected
        if @connected
          @connected = false
          @last_disconnect_time = Time.now
          trigger_connection_callback(:connection_error, { error: e.message })
          handle_auto_reconnect if @auto_reconnect
        end
        false
      end
    end
    
    def self.finalize_proc(connection_data)
      proc do
        if connection_data
          begin
            Quicsilver.disconnect_handle(connection_data)
          rescue => e
            # Ignore errors during finalization
          end
        end
      end
    end
    
    def finalize
      disconnect
    end
    
    private
    
    def attempt_connection
      raise Error, "Already connected" if @connected
      
      begin
        # Initialize MSQUIC if not already done
        Quicsilver.open_connection
        
        # Create configuration
        config = Quicsilver.create_configuration(@unsecure)
        raise ConnectionError, "Failed to create configuration" if config.nil?
        
        # Create connection (returns [handle, context])
        @connection_data = Quicsilver.create_connection
        raise ConnectionError, "Failed to create connection" if @connection_data.nil?
        
        connection_handle = @connection_data[0]
        context_handle = @connection_data[1]
        
        # Start the connection
        success = Quicsilver.start_connection(connection_handle, config, @hostname, @port)
        unless success
          Quicsilver.close_configuration(config)
          cleanup_failed_connection
          raise ConnectionError, "Failed to start connection"
        end
        
        # Wait for connection to establish or fail
        result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)
        
        if result.key?("error")
          error_status = result["status"]
          error_code = result["code"]
          Quicsilver.close_configuration(config)
          cleanup_failed_connection
          error_msg = "Connection failed with status: 0x#{error_status.to_s(16)}, code: #{error_code}"
          raise ConnectionError, error_msg
        elsif result.key?("timeout")
          Quicsilver.close_configuration(config)
          cleanup_failed_connection
          error_msg = "Connection timed out after #{@connection_timeout}ms"
          raise TimeoutError, error_msg
        end
        
        @connected = true
        @connection_start_time = Time.now
        @streams = []
        
        # Clean up config since connection is established
        Quicsilver.close_configuration(config)
        
        trigger_connection_callback(:connected, connection_info)
        
      rescue => e
        cleanup_failed_connection
        
        if e.is_a?(ConnectionError) || e.is_a?(TimeoutError)
          raise e
        else
          raise ConnectionError, "Connection failed: #{e.message}"
        end
      end
    end
    
    def cleanup_failed_connection
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      @connection_data = nil
      @connected = false
      @streams = []
    end
    
    def ensure_connected
      return if connected?
      
      if @auto_reconnect && @hostname && @port
        begin
          reconnect
        rescue Error => e
          raise ConnectionError, "Auto-reconnect failed: #{e.message}"
        end
      else
        raise ConnectionError, "Not connected. Call connect() first."
      end
    end
    
    def handle_auto_reconnect
      return unless @auto_reconnect
      return if @reconnect_attempts >= @max_reconnect_attempts
      
      Thread.new do
        sleep(@reconnect_delay / 1000.0)
        begin
          reconnect if @hostname && @port && !@connected
        rescue => e
          # Auto-reconnect failed, will be handled by reconnect method
        end
      end
    end
    
    def add_stream(stream)
      @streams << stream
      trigger_callback(:stream_opened, stream)
    end
    
    def check_stream_limit
      cleanup_closed_streams
      if @streams.size >= @max_concurrent_streams
        raise Error, "Maximum concurrent streams (#{@max_concurrent_streams}) reached"
      end
    end
    
    def cleanup_closed_streams
      before_count = @streams.size
      @streams.reject! do |stream|
        if stream.closed? || stream.failed?
          begin
            stream.close unless stream.closed?
          rescue => e
            # Ignore cleanup errors
          end
          true
        else
          false
        end
      end
      
      if @streams.size < before_count
        trigger_callback(:streams_cleaned_up, { 
          removed: before_count - @streams.size,
          remaining: @streams.size 
        })
      end
    end
    
    def trigger_callback(event, *args)
      callback = @stream_callbacks[event]
      callback.call(*args) if callback.respond_to?(:call)
    end
    
    def trigger_connection_callback(event, *args)
      callback = @connection_callbacks[event]
      callback.call(*args) if callback.respond_to?(:call)
    end
  end
end
