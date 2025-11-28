# frozen_string_literal: true

require_relative "quicsilver/version"
require_relative "quicsilver/client"
require_relative "quicsilver/connection"
require_relative "quicsilver/event_loop"
require_relative "quicsilver/quic_stream"
require_relative "quicsilver/listener_data"
require_relative "quicsilver/server"
require_relative "quicsilver/server_configuration"
require_relative "quicsilver/http3"
require_relative "quicsilver/http3/request_parser"
require_relative "quicsilver/http3/request_encoder"
require_relative "quicsilver/http3/response_encoder"
require_relative "quicsilver/quicsilver"
require_relative "rackup/handler/quicsilver"

module Quicsilver
  class Error < StandardError; end
  class ServerIsRunningError < Error; end
  class ServerConfigurationError < Error; end
  class ServerListenerError < Error; end
  class ServerError < Error; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
end