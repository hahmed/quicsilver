# frozen_string_literal: true

require_relative "quicsilver/version"
require_relative "quicsilver/quicsilver"
require_relative "quicsilver/connection_pool"
require_relative "quicsilver/stream_manager"
require_relative "quicsilver/stream"
require_relative "quicsilver/client"
require_relative "quicsilver/server"
require "securerandom"

module Quicsilver
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class StreamError < Error; end

  def self.connect(hostname, port = 4433, **options, &block)
    client = Client.new(**options)
    client.connect(hostname, port)
    
    if block_given?
      begin
        yield client
      ensure
        client.disconnect
      end
    else
      client
    end
  end
end