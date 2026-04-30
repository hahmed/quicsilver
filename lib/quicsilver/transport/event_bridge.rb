# frozen_string_literal: true

module Quicsilver
  module Transport
    # Base class for event bridges.
    #
    # An event bridge connects MsQuic's C callbacks to Ruby's event processing.
    # C callbacks write events to a ring buffer and signal the bridge.
    # Ruby waits on the bridge, then drains the buffer.
    #
    # Subclasses implement the wait mechanism:
    # - PipeEventBridge: IO.select on a notification pipe (thread mode)
    # - SelectorEventBridge: io-event selector (fiber mode, future)
    #
    class EventBridge
      # Block until events are ready or timeout expires.
      def wait(timeout: 1.0)
        raise NotImplementedError
      end

      # Signal that events are available (called from C).
      def signal
        raise NotImplementedError
      end

      # Clean up resources.
      def close
        raise NotImplementedError
      end
    end
  end
end
