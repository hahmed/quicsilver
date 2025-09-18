# frozen_string_literal: true

require_relative "quicsilver/version"
require_relative "quicsilver/quicsilver"
require_relative "quicsilver/client"
require_relative "quicsilver/listener_data"
require_relative "quicsilver/server"
require_relative "quicsilver/server_configuration"

module Quicsilver
  class Error < StandardError; end
  class ServerIsRunningError < Error; end
  class ServerConfigurationError < Error; end
  class ServerListenerError < Error; end
  class ServerError < Error; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
end