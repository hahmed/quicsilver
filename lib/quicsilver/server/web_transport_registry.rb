# frozen_string_literal: true

require_relative "web_transport_manager"

module Quicsilver
  class Server
    # One WebTransportManager per QUIC connection.
    #
    # A session is identified by its CONNECT stream id, and QUIC stream ids
    # restart on every connection, so two clients routinely both have a session
    # on stream 0. Sharing one manager across connections routed streams into
    # the wrong client's session.
    class WebTransportRegistry
      def initialize
        @managers = {}
        @mutex = Mutex.new
      end

      # The manager owning this connection's sessions, created on first use.
      def for(connection_handle)
        @mutex.synchronize do
          @managers[connection_handle] ||= WebTransportManager.new
        end
      end

      # Forget a connection, returning its sessions so the caller can notify
      # them.
      def drop(connection_handle)
        manager = @mutex.synchronize { @managers.delete(connection_handle) }
        return [] unless manager

        manager.sessions
      end

      def connection_count
        @mutex.synchronize { @managers.size }
      end
    end
  end
end
