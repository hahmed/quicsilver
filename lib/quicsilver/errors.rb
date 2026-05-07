# frozen_string_literal: true

module Quicsilver
  class Error < StandardError; end
  class ServerIsRunningError < Error; end
  class ServerConfigurationError < Error; end
  class ServerListenerError < Error; end
  class ServerError < Error; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class GoAwayError < Error; end
  class StreamFailedToOpenError < Error; end
  class CancelledError < Error; end
end
