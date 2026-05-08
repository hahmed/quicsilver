# frozen_string_literal: true

module Quicsilver
  class Error < StandardError; end

  # Transport errors from MsQuic. The C extension raises RuntimeError
  # which Ruby call sites wrap into typed TransportError subclasses.
  # Carries the MsQuic QUIC_STATUS code parsed from the error message.
  #
  #   rescue Quicsilver::TransportError => e
  #     e.message  # => "StreamOpen failed, 0x1!"
  #     e.status   # => 1 (QUIC_STATUS_INVALID_STATE / EPERM)
  #
  class TransportError < Error
    attr_reader :status

    def initialize(message = nil, status: 0)
      @status = status
      super(message)
    end

    # Parse MsQuic hex status from C extension error messages.
    # "StreamOpen failed, 0x1!" => 0x1 (EPERM / INVALID_STATE)
    def self.parse_status(message)
      message&.match(/0x([0-9a-fA-F]+)/) { |m| m[1].to_i(16) } || 0
    end
  end

  class ServerIsRunningError < Error; end
  class ServerConfigurationError < Error; end
  class ServerListenerError < Error; end
  class ServerError < Error; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class GoAwayError < Error; end
  class StreamFailedToOpenError < TransportError; end
  class CancelledError < Error; end

end
