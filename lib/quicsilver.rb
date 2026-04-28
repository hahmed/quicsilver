# frozen_string_literal: true

require "logger"
require_relative "quicsilver/version"

# Protocol layer
require_relative "quicsilver/protocol/frames"
require_relative "quicsilver/protocol/priority"
require_relative "quicsilver/protocol/qpack/encoder"
require_relative "quicsilver/protocol/request_parser"
require_relative "quicsilver/protocol/request_encoder"
require_relative "quicsilver/protocol/response_parser"
require_relative "quicsilver/protocol/response_encoder"
require_relative "quicsilver/protocol/stream_input"
require_relative "quicsilver/protocol/stream_output"
require_relative "quicsilver/protocol/adapter"
require_relative "quicsilver/protocol/control_stream_parser"
require "protocol/rack"

# Transport layer
require_relative "quicsilver/transport/stream"
require_relative "quicsilver/transport/stream_event"
require_relative "quicsilver/transport/inbound_stream"
require_relative "quicsilver/transport/event_loop"
require_relative "quicsilver/transport/configuration"
require_relative "quicsilver/transport/connection"
require_relative "quicsilver/transport/connection_stats"

# Server
require_relative "quicsilver/server/listener_data"
require_relative "quicsilver/server/request_registry"
require_relative "quicsilver/server/request_handler"
require_relative "quicsilver/server/server"

# Client
require_relative "quicsilver/client/request"
require_relative "quicsilver/client/connection_pool"
require_relative "quicsilver/client/client"

# C extension
# Load precompiled binary if available, fall back to native extension
begin
  ruby_version = /(\d+\.\d+)/.match(RUBY_VERSION)
  require_relative "quicsilver/#{ruby_version}/quicsilver"
rescue LoadError
  require_relative "quicsilver/quicsilver"
end

# Rackup handler
require_relative "rackup/handler/quicsilver"

module Quicsilver
  class Error < StandardError; end
  class ServerIsRunningError < Error; end
  class ServerConfigurationError < Error; end
  class ServerListenerError < Error; end
  class ServerError < Error; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end

  class << self
    attr_writer :logger

    def logger
      @logger ||= default_logger
    end

    private

    def default_logger
      Logger.new($stdout, level: Logger::INFO).tap do |log|
        log.progname = "Quicsilver"
      end
    end
  end

  # Release pooled client connections on process exit.
  # Closes connection handles so the OS doesn't leak UDP sockets.
  # MsQuic itself is cleaned up by the OS when the process exits.
  at_exit do
    begin
      Client.close_pool
    rescue StandardError # rubocop:disable Lint/SuppressedException
    end
  end
end
