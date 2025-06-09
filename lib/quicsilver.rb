# frozen_string_literal: true

require "quicsilver/version"
require "quicsilver/quicsilver"

module Quicsilver
  class Error < StandardError; end

  class Client
    def initialize(unsecure: true)
      @unsecure = unsecure
      @config = nil
      @connection = nil
      @connected = false
      
      # Initialize MSQUIC if not already done
      Quicsilver.open_connection
    end
    
    def connect(hostname, port = 4433)
      raise Error, "Already connected" if @connected
      
      # Create configuration
      @config = Quicsilver.create_configuration(@unsecure)
      raise Error, "Failed to create configuration" if @config.nil?
      
      # Create connection
      @connection = Quicsilver.create_connection
      raise Error, "Failed to create connection" if @connection.nil?
      
      # Start the connection
      success = Quicsilver.start_connection(@connection, @config, hostname, port)
      raise Error, "Failed to start connection" unless success
      
      @connected = true
      puts "Connected to #{hostname}:#{port}"
      
      # TODO: implement connection event handling
      true
    end
    
    def disconnect
      return unless @connected
      
      # Close connection (in reverse order of creation)
      Quicsilver.close_connection_handle(@connection) if @connection
      Quicsilver.close_configuration(@config) if @config
      
      @connection = nil
      @config = nil
      @connected = false
      
      puts "Disconnected"
    end
    
    def connected?
      @connected
    end
    
    # Auto-cleanup when object is garbage collected
    def finalize
      disconnect
    end
  end
  
  def self.connect(hostname, port = 4433, unsecure: true)
    client = Client.new(unsecure: unsecure)
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