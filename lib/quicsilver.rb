# frozen_string_literal: true

require "logger"
require_relative "quicsilver/version"
require_relative "quicsilver/errors"
require_relative "quicsilver/response"

# Protocol layer
require_relative "quicsilver/protocol/frames"
require_relative "quicsilver/protocol/datagram"
require_relative "quicsilver/protocol/capsule"
require_relative "quicsilver/protocol/web_transport"
require_relative "quicsilver/protocol/unidirectional_stream"
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

# Rack integration
require_relative "quicsilver/rack/context"

# Transport layer
require_relative "quicsilver/transport/stream_id"
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
require_relative "quicsilver/server/rack_adapter"
require_relative "quicsilver/server/web_transport_flow_control"
require_relative "quicsilver/server/web_transport_manager"
require_relative "quicsilver/server/server"

# Client
require_relative "quicsilver/client/request"
require_relative "quicsilver/client/connection_pool"
require_relative "quicsilver/client/client"

# C extension. Quicsilver::Extension::REQUIRE_PATHS is ordered most to least specific: a build made
# by this exact Ruby install, then any build for this ABI, then the flat path a released gem ships.
#
# Every candidate can fail for two different reasons — absent, or present but linked against another
# Ruby — and dyld reports the second from deep inside Bundler with a message that names no fix. Keep
# trying the rest, then re-raise with every reason listed.
require_relative "quicsilver/extension"

extension_errors = []
Quicsilver::Extension::REQUIRE_PATHS.each do |candidate|
  begin
    require candidate
    extension_errors.clear
    break
  rescue LoadError => error
    extension_errors << "#{candidate}: #{error.message}"
  end
end

unless extension_errors.empty?
  raise LoadError, <<~MESSAGE.strip
    quicsilver has no usable C extension for Ruby #{RUBY_VERSION} (#{RbConfig::CONFIG["prefix"]}).

    Build one with: rake compile

    Tried:
    #{extension_errors.join("\n")}
  MESSAGE
end

# Rackup handler
require_relative "rackup/handler/quicsilver"

module Quicsilver
  class << self
    attr_writer :logger

    def stream_abort(handle, error_code)
      receiving_stopped = stream_stop_sending(handle, error_code)
      sending_reset = stream_reset(handle, error_code)
      receiving_stopped || sending_reset
    end

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
