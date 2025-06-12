# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :server_id, :cert_file, :key_file, :address, :port, :max_connections, :listener_data
    
    def initialize(cert_file:, key_file:, address: "127.0.0.1", port: 4433, max_connections: 100)
      @cert_file = cert_file
      @key_file = key_file
      @address = address
      @port = port
      @max_connections = max_connections
      @server_id = SecureRandom.hex(8)
      @listener_data = nil
      @running = false
      @connection_callbacks = {}
      
      # Validate certificate files exist
      unless File.exist?(@cert_file)
        raise Error, "Certificate file not found: #{@cert_file}"
      end
      
      unless File.exist?(@key_file)
        raise Error, "Private key file not found: #{@key_file}"
      end
      
      ObjectSpace.define_finalizer(self, self.class.finalize_proc(@listener_data))
    end
    
    def start(&block)
      raise Error, "Server is already running" if @running
      
      begin
        # Initialize MSQUIC if not already done
        Quicsilver.open_connection
        
        # First cleanup any existing port usage
        begin
          config = Quicsilver.create_server_configuration(@cert_file, @key_file)
          if config
            existing_listener = Quicsilver.create_listener(config)
            if existing_listener
              Quicsilver.stop_listener(existing_listener[0])
              Quicsilver.close_listener(existing_listener)
            end
            Quicsilver.close_configuration(config)
          end
        rescue => e
          # Ignore cleanup errors
        end
        
        # Create server configuration
        config = Quicsilver.create_server_configuration(@cert_file, @key_file)
        unless config
          raise Error, "Failed to create server configuration"
        end
        
        # Create and start the listener
        @listener_data = Quicsilver.create_listener(config)
        
        unless @listener_data
          Quicsilver.close_configuration(config)
          raise Error, "Failed to create listener on #{@address}:#{@port}"
        end
        
        # Start the listener 
        listener_handle = @listener_data[0]
        result = Quicsilver.start_listener(listener_handle, @address, @port)
        unless result
          Quicsilver.close_configuration(config)
          cleanup_failed_server
          raise Error, "Failed to start listener on #{@address}:#{@port}"
        end
        
        @running = true
        
        puts "✅ QUIC server started successfully on #{@address}:#{@port}"
        puts "📋 Server ID: #{@server_id}"
        puts "📄 Certificate: #{@cert_file}"
        puts "🔑 Private Key: #{@key_file}"
        
        # Clean up config since listener is started
        Quicsilver.close_configuration(config)
        
        # If a block is provided, call it and then stop the server
        if block_given?
          begin
            yield self
          ensure
            stop
          end
        end
        
      rescue => e
        cleanup_failed_server
        @running = false
        
        error_msg = case e.message
        when /0x16/
          "Invalid parameter error - check certificate files and network configuration"
        when /0x30/
          "Address already in use - port #{@port} may be occupied"
        else
          e.message
        end
        
        raise Error, "Server start failed: #{error_msg}"
      end
    end
    
    def stop
      return unless @running
      
      begin
        puts "🛑 Stopping QUIC server..."
        
        if @listener_data
          listener_handle = @listener_data[0]
          Quicsilver.stop_listener(listener_handle)
          Quicsilver.close_listener(@listener_data)
          @listener_data = nil
        end
        
        @running = false
        puts "👋 Server stopped"
        
      rescue => e
        puts "⚠️  Error during server shutdown: #{e.message}"
        # Continue with cleanup even if there are errors
        @listener_data = nil
        @running = false
      end
    end
    
    def running?
      @running
    end
    
    def server_info
      {
        server_id: @server_id,
        address: @address,
        port: @port,
        running: @running,
        cert_file: @cert_file,
        key_file: @key_file,
        max_connections: @max_connections
      }
    end
    
    def on_connection(&block)
      @connection_callbacks[:connection] = block
      puts "DEBUG: on_connection callback set"
    end
    
    def on_disconnection(&block)
      @connection_callbacks[:disconnection] = block
    end
    
    def wait_for_connections(timeout: nil)
      start_time = Time.now
      
      while @running
        sleep(0.1)
        
        if timeout && (Time.now - start_time) > timeout
          break
        end
      end
    end
    
    def self.finalize_proc(listener_data)
      proc do
        if listener_data
          begin
            Quicsilver.stop_listener(listener_data)
            Quicsilver.close_listener(listener_data)
          rescue => e
            # Ignore errors during finalization
          end
        end
      end
    end
    
    def finalize
      stop
    end
    
    private
    
    def cleanup_failed_server
      if @listener_data
        begin
          Quicsilver.stop_listener(@listener_data)
          Quicsilver.close_listener(@listener_data)
        rescue => e
          # Ignore cleanup errors
        ensure
          @listener_data = nil
        end
      end
    end
    
    def trigger_connection_callback(event, data)
      callback = @connection_callbacks[event]
      callback.call(data) if callback.respond_to?(:call)
    rescue => e
      puts "Error in connection callback: #{e.message}"
    end
  end
end
