# frozen_string_literal: true

require "logger"
require_relative "quicsilver/version"

# Protocol layer (pure HTTP/3 codec)
require_relative "quicsilver/protocol/frames"
require_relative "quicsilver/protocol/qpack/encoder"
require_relative "quicsilver/protocol/request_parser"
require_relative "quicsilver/protocol/request_encoder"
require_relative "quicsilver/protocol/response_parser"
require_relative "quicsilver/protocol/response_encoder"

# Transport layer (QUIC primitives)
require_relative "quicsilver/transport/stream"
require_relative "quicsilver/transport/stream_event"
require_relative "quicsilver/transport/inbound_stream"
require_relative "quicsilver/transport/event_loop"
require_relative "quicsilver/transport/configuration"
require_relative "quicsilver/transport/connection"

# Server
require_relative "quicsilver/server/listener_data"
require_relative "quicsilver/server/request_registry"
require_relative "quicsilver/server/request_handler"
require_relative "quicsilver/server/server"

# Client
require_relative "quicsilver/client/request"
require_relative "quicsilver/client/client"

# C extension
require_relative "quicsilver/quicsilver"

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
end
