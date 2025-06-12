# frozen_string_literal: true

module Quicsilver
  class Stream
    attr_reader :stream_id, :bidirectional, :client, :stream_data, :stream_timeout
    
    def initialize(client, bidirectional: true, stream_timeout: 5000)
      @client = client
      @bidirectional = bidirectional
      @stream_timeout = stream_timeout
      @stream_data = nil
      @stream_id = nil
      @opened = false
      
      # Open the stream using the connection handle
      connection_handle = @client.connection_data[0]
      @stream_data = Quicsilver.create_stream(connection_handle, @bidirectional)
      
      if @stream_data
        @stream_id = SecureRandom.hex(8)
        @opened = true
        @client.add_stream(self)
      end
    end
    
    def opened?
      return false unless @stream_data
      
      begin
        context_handle = @stream_data[1]
        status_info = Quicsilver.stream_status(context_handle)
        status_info && status_info["opened"] && !status_info["failed"]
      rescue => e
        false
      end
    end
    
    def closed?
      return true unless @stream_data
      
      begin
        context_handle = @stream_data[1]
        status_info = Quicsilver.stream_status(context_handle)
        !status_info || status_info["closed"]
      rescue => e
        true
      end
    end
    
    def failed?
      return false unless @stream_data
      
      begin
        context_handle = @stream_data[1]
        status_info = Quicsilver.stream_status(context_handle)
        status_info && status_info["failed"]
      rescue => e
        true
      end
    end
    
    def status
      return nil unless @stream_data
      
      begin
        context_handle = @stream_data[1]
        Quicsilver.stream_status(context_handle)
      rescue => e
        nil
      end
    end
    
    def send(data)
      raise Error, "Stream not opened" unless opened?
      
      begin
        stream_handle = @stream_data[0]
        result = Quicsilver.stream_send(stream_handle, data.to_s)
        unless result
          raise StreamError, "Failed to send data on stream"
        end
        
        result
      rescue => e
        if e.is_a?(StreamError)
          raise e
        else
          raise StreamError, "Stream send error: #{e.message}"
        end
      end
    end
    
    def receive(timeout: 1000)
      raise Error, "Stream not opened" unless opened?
      
      begin
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
        data = Quicsilver.stream_receive(context_handle)
        
        if data.nil? || data.empty?
          # Check if stream is still valid
          unless opened?
            raise StreamError, "Stream closed during receive"
          end
        end
        
        data
      rescue => e
        if e.is_a?(StreamError)
          raise e
        else
          raise StreamError, "Stream receive error: #{e.message}"
        end
      end
    end
    
    def has_data?
      return false unless @stream_data
      
      begin
        context_handle = @stream_data[1]
        Quicsilver.stream_has_data(context_handle)
      rescue => e
        false
      end
    end
    
    def shutdown_send
      return unless @stream_data
      
      begin
        stream_handle = @stream_data[0]
        Quicsilver.stream_shutdown_send(stream_handle)
      rescue => e
        # Ignore errors during shutdown
      end
    end
    
    def close
      return unless @stream_data
      
      begin
        Quicsilver.close_stream(@stream_data)
      ensure
        @stream_data = nil
        @opened = false
      end
    end
    
    def wait_for_open
      return unless @stream_data
      
      start_time = Time.now
      while Time.now - start_time < (@stream_timeout / 1000.0)
        if opened?
          return true
        end
        sleep(0.01) # 10ms polling
      end
      
      false
    end
    
    def finalize
      close
    end
  end
end
