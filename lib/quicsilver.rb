# frozen_string_literal: true

require "quicsilver/version"
require "quicsilver/quicsilver"

module Quicsilver
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class StreamError < Error; end

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
    attr_reader :connection_data
    
    def initialize(unsecure: true, connection_timeout: 5000)
      @unsecure = unsecure
      @connection_timeout = connection_timeout
      @config = nil
      @connection_data = nil
      @connected = false
      @streams = []
      
      # Initialize MSQUIC if not already done
      Quicsilver.open_connection
    end
    
    def connect(hostname, port = 4433)
      raise Error, "Already connected" if @connected
      
      # Create configuration
      @config = Quicsilver.create_configuration(@unsecure)
      raise Error, "Failed to create configuration" if @config.nil?
      
      # Create connection (returns [handle, context])
      @connection_data = Quicsilver.create_connection
      raise Error, "Failed to create connection" if @connection_data.nil?
      
      connection_handle = @connection_data[0]
      context_handle = @connection_data[1]
      
      # Start the connection
      success = Quicsilver.start_connection(connection_handle, @config, hostname, port)
      raise Error, "Failed to start connection" unless success
      
      # Wait for connection to establish or fail
      result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)
      
      if result.key?("error")
        error_status = result["status"]
        error_code = result["code"]
        disconnect
        raise ConnectionError, "Connection failed with status: 0x#{error_status.to_s(16)}, code: #{error_code}"
      elsif result.key?("timeout")
        disconnect
        raise TimeoutError, "Connection timed out after #{@connection_timeout}ms"
      end
      
      @connected = true
      puts "Connected to #{hostname}:#{port}"
      true
    end
    
    def open_bidirectional_stream(**options)
      raise Error, "Not connected" unless connected?
      
      stream = Stream.new(self, bidirectional: true, **options)
      @streams << stream
      stream
    end
    
    def open_unidirectional_stream(**options) 
      raise Error, "Not connected" unless connected?
      
      stream = Stream.new(self, bidirectional: false, **options)
      @streams << stream
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
      @streams.dup
    end
    
    def disconnect
      return unless @connected || @connection_data
      
      # Close all streams first
      @streams.each(&:close)
      @streams.clear
      
      # Close connection (in reverse order of creation)
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      Quicsilver.close_configuration(@config) if @config
      
      @connection_data = nil
      @config = nil
      @connected = false
      
      puts "Disconnected" if @connected
    end
    
    def connected?
      return false unless @connected && @connection_data
      
      # Check actual connection status
      context_handle = @connection_data[1]
      status = Quicsilver.connection_status(context_handle)
      
      @connected = status["connected"] && !status["failed"]
      @connected
    end
    
    def connection_info
      return nil unless @connection_data
      
      context_handle = @connection_data[1]
      Quicsilver.connection_status(context_handle)
    end
    
    # Auto-cleanup when object is garbage collected
    def finalize
      disconnect
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