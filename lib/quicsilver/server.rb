# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :cert_file, :key_file, :running
    
    def initialize(port = 4433, address: "0.0.0.0", cert_file: nil, key_file: nil)
      @port = port
      @address = address
      @cert_file = cert_file || "certs/server.crt"
      @key_file = key_file || "certs/server.key"
      @running = false
      @listener_data = nil
    end
    
    def start
      raise ServerIsRunningError, "Server is already running" if @running
      
      # Initialize MSQUIC if not already done
      Quicsilver.open_connection
      
      # Create server configuration
      config = Quicsilver.create_server_configuration(@cert_file, @key_file)
      unless config
        raise ServerConfigurationError, "Failed to create server configuration"
      end
      
      # Create and start the listener
      @listener_data = Quicsilver.create_listener(config)
      
      unless @listener_data
        Quicsilver.close_configuration(config)
        raise ServerListenerError, "Failed to create listener on #{@address}:#{@port}"
      end
      
      # Start the listener 
      listener_handle = @listener_data[0]
      result = Quicsilver.start_listener(listener_handle, @address, @port)
      unless result
        Quicsilver.close_configuration(config)
        cleanup_failed_server
        raise ServerListenerError, "Failed to start listener on #{@address}:#{@port}"
      end
      
      @running = true
      
      puts "✅ QUIC server started successfully on #{@address}:#{@port}"
      puts "📄 Certificate: #{@cert_file}"
      puts "🔑 Private Key: #{@key_file}"
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
      
      raise ServerError, "Server start failed: #{error_msg}"
    end
    
    def stop
      return unless @running
      
      puts "🛑 Stopping QUIC server..."
      
      if @listener_data
        listener_handle = @listener_data[0]
        Quicsilver.stop_listener(listener_handle)
        Quicsilver.close_listener(@listener_data)
        @listener_data = nil
      end
      
      @running = false
      puts "👋 Server stopped"    
    rescue
      puts "⚠️  Error during server shutdown"
      # Continue with cleanup even if there are errors
      @listener_data = nil
      @running = false
    end
    
    def running?
      @running
    end
    
    def server_info
      {
        address: @address,
        port: @port,
        running: @running,
        cert_file: @cert_file,
        key_file: @key_file
      }
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
    
    private
    
    def cleanup_failed_server
      if @listener_data
        begin
          Quicsilver.stop_listener(@listener_data)
          Quicsilver.close_listener(@listener_data)
        rescue
          # Ignore cleanup errors
        ensure
          @listener_data = nil
        end
      end
    end
  end
end
