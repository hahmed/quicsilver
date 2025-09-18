# frozen_string_literal: true

module Quicsilver
  class Server
    attr_reader :address, :port, :server_configuration, :running
    
    def initialize(port = 4433, address: "0.0.0.0", server_configuration: nil)
      @port = port
      @address = address
      @server_configuration = server_configuration || ServerConfiguration.new
      @running = false
      @listener_data = nil
    end
    
    def start
      raise ServerIsRunningError, "Server is already running" if @running
      
      # Initialize MSQUIC if not already done
      Quicsilver.open_connection
      
      # Create server configuration
      config = Quicsilver.create_server_configuration(@server_configuration.to_h)
      unless config
        raise ServerConfigurationError, "Failed to create server configuration"
      end
      
      # Create and start the listener
      @listener_data = start_listener(config)
      start_server(config)
      
      @running = true
      
      puts "✅ QUIC server started successfully on #{@address}:#{@port}"
    rescue ServerConfigurationError, ServerListenerError => e
      cleanup_failed_server
      @running = false
      raise e
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

    def start_server(config)
      result = Quicsilver.start_listener(@listener_data.listener_handle, @address, @port)
      unless result
        Quicsilver.close_configuration(config)
        cleanup_failed_server
        raise ServerListenerError, "Failed to start listener on #{@address}:#{@port}"
      end
    end

    def start_listener(config)
      result = Quicsilver.create_listener(config)
      listener_data = ListenerData.new(result[0], result[1])

      unless listener_data
        Quicsilver.close_configuration(config)
        raise ServerListenerError, "Failed to create listener on #{@address}:#{@port}"
      end

      listener_data
    end
    
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
