# frozen_string_literal: true

require "quicsilver/version"
require "quicsilver/quicsilver"

module Quicsilver
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end

  class Client
    def initialize(unsecure: true, connection_timeout: 5000)
      @unsecure = unsecure
      @connection_timeout = connection_timeout
      @config = nil
      @connection_data = nil
      @connected = false
      
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
    
    def disconnect
      return unless @connected || @connection_data
      
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