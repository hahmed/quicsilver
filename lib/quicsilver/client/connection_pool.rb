# frozen_string_literal: true

module Quicsilver
  class Client
    # Thread-safe pool of connected Client instances, keyed by (host, port).
    # Idle connections are reused automatically. Stale ones are evicted at checkout.
    #
    #   Quicsilver::Client.get("example.com", 4433, "/users")
    #
    class ConnectionPool
      attr_reader :max_size, :idle_timeout

      DEFAULT_MAX_SIZE = 4
      DEFAULT_IDLE_TIMEOUT = 60 # seconds

      def initialize(max_size: DEFAULT_MAX_SIZE, idle_timeout: DEFAULT_IDLE_TIMEOUT)
        @max_size = max_size
        @idle_timeout = idle_timeout
        @pools = {} # "host:port" => [{ client:, checked_out: }]
        @mutex = Mutex.new
      end

      # Check out a connected Client. Reuses an idle one or creates a new one.
      def checkout(hostname, port, **options)
        key = "#{hostname}:#{port}"

        @mutex.synchronize do
          entries = @pools[key] ||= []

          # Evict dead/stale
          entries.reject! do |e|
            if !e[:checked_out] && (!e[:client].connected? || e[:last_used] < Time.now - @idle_timeout)
              e[:client].close_connection
              true
            end
          end

          # Reuse an idle client
          idle = entries.find { |e| !e[:checked_out] && e[:client].connected? }
          if idle
            idle[:checked_out] = true
            idle[:last_used] = Time.now
            return idle[:client]
          end

          if entries.size >= @max_size
            raise ConnectionError, "Connection pool full for #{key} (max: #{@max_size})"
          end
        end

        # Create outside the lock (blocking I/O)
        client = Client.new(hostname, port, **options)
        client.open_connection

        @mutex.synchronize do
          (@pools[key] ||= []) << { client: client, checked_out: true, last_used: Time.now }
        end

        client
      end

      # Return a Client to the pool.
      def checkin(client)
        key = "#{client.hostname}:#{client.port}"

        @mutex.synchronize do
          entries = @pools[key]
          return unless entries

          entry = entries.find { |e| e[:client].equal?(client) }
          return unless entry

          if client.connected?
            entry[:checked_out] = false
            entry[:last_used] = Time.now
          else
            entries.delete(entry)
            client.close_connection
            @pools.delete(key) if entries.empty?
          end
        end
      end

      # Close all clients.
      def close
        @mutex.synchronize do
          @pools.each_value do |entries|
            entries.each { |e| e[:client].close_connection }
          end
          @pools.clear
        end
      end

      # Total clients in the pool, optionally filtered by host:port.
      def size(host = nil, port = nil)
        @mutex.synchronize do
          if host && port
            (@pools["#{host}:#{port}"] || []).size
          else
            @pools.values.sum(&:size)
          end
        end
      end
    end
  end
end
