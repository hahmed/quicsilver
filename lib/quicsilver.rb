# frozen_string_literal: true

require_relative "quicsilver/version"
require_relative "quicsilver/quicsilver"
require_relative "quicsilver/client"
require_relative "quicsilver/server"

module Quicsilver
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
end