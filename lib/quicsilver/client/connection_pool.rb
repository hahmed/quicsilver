# frozen_string_literal: true

module Quicsilver
  class Client
    # Thread-safe pool of connected Client instances, keyed by (host, port).
    # Idle connections are reused automatically. Stale ones are evicted at checkout.
    #
    #   Quicsilver::Client.get("example.com", 4433, "/users")
    #
    class ConnectionPool
      attr_reader :max_size, :idle_timeout, :mode

      DEFAULT_MAX_SIZE = 4
      DEFAULT_IDLE_TIMEOUT = 60 # seconds
      DEFAULT_CHECKOUT_TIMEOUT = 5 # seconds

      # @param mode [:exclusive, :shared] Pool strategy.
      #   :shared (default) — one connection per host, all threads share it via
      #     QUIC stream multiplexing. 5x faster, one TLS handshake per host.
      #   :exclusive — one connection per checkout, like ActiveRecord. Use for
      #     maintenance tasks that need isolation or servers with low stream limits.
      def initialize(max_size: DEFAULT_MAX_SIZE, idle_timeout: DEFAULT_IDLE_TIMEOUT, checkout_timeout: DEFAULT_CHECKOUT_TIMEOUT, mode: :shared)
        @max_size = max_size
        @idle_timeout = idle_timeout
        @checkout_timeout = checkout_timeout
        @mode = mode
        @pools = {} # "host:port" => [{ client:, checked_out: }]
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      # Check out a connected Client. Reuses an idle one or creates a new one.
      # In :exclusive mode, blocks with timeout if pool is full.
      # In :shared mode, returns the shared connection (all threads use one connection).
      def checkout(hostname, port, **options)
        @mode == :shared ? checkout_shared(hostname, port, **options) : checkout_exclusive(hostname, port, **options)
      end

      private def checkout_exclusive(hostname, port, **options)
        key = "#{hostname}:#{port}"
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @checkout_timeout

        @mutex.synchronize do
          loop do
            entries = @pools[key] ||= []

            # Evict dead/stale/draining
            entries.reject! do |e|
              if !e[:checked_out] && (!e[:client].connected? || e[:client].draining? || e[:last_used] < Time.now - @idle_timeout)
                e[:client].close_connection
                true
              end
            end

            # Reuse an idle client (skip draining ones)
            idle = entries.find { |e| !e[:checked_out] && e[:client].connected? && !e[:client].draining? }
            if idle
              idle[:checked_out] = true
              idle[:last_used] = Time.now
              return idle[:client]
            end

            # Room to create a new connection
            break if entries.size < @max_size

            # Pool full — wait for a checkin
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise ConnectionError, "Connection pool full for #{key} (waited #{@checkout_timeout}s, max: #{@max_size})" if remaining <= 0
            @condition.wait(@mutex, remaining)
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

      # Shared mode: one connection per host, all threads share it.
      # Each thread opens its own QUIC stream on the shared connection.
      # No checkout/checkin semantics — the connection is never "owned".
      private def checkout_shared(hostname, port, **options)
        key = "#{hostname}:#{port}"

        @mutex.synchronize do
          entry = @pools[key]&.first
          if entry && entry[:client].connected? && !entry[:client].draining?
            entry[:last_used] = Time.now
            return entry[:client]
          end
          # Remove stale entry
          @pools.delete(key) if entry
        end

        # Create outside the lock (blocking I/O)
        client = Client.new(hostname, port, **options)
        client.open_connection

        @mutex.synchronize do
          # Double-check — another thread may have created one while we were connecting
          existing = @pools[key]&.first
          if existing && existing[:client].connected? && !existing[:client].draining?
            client.close_connection
            existing[:last_used] = Time.now
            return existing[:client]
          end
          @pools[key] = [{ client: client, checked_out: false, last_used: Time.now }]
        end

        client
      end

      # Block-based checkout — auto-checkin on completion or error.
      #
      #   pool.with("example.com", 443) { |client| client.get("/") }
      #
      def with(hostname, port, **options)
        client = checkout(hostname, port, **options)
        yield client
      ensure
        checkin(client) if client
      end

      # Return a Client to the pool. No-op in shared mode.
      def checkin(client)
        return if @mode == :shared
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

          @condition.broadcast  # wake threads waiting for a connection
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
