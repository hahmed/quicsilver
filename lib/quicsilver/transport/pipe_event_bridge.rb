# frozen_string_literal: true

require_relative "event_bridge"

module Quicsilver
  module Transport
    # Thread-mode bridge: watches the notification pipe via IO.select.
    # No fibers, no io-event dependency. Works everywhere.
    #
    # C callbacks write to the pipe's write end. This bridge waits
    # on the read end via IO.select, which releases the GVL so
    # other Ruby threads can run while waiting.
    #
    class PipeEventBridge < EventBridge
      def initialize
        fd = Quicsilver.notify_fd
        raise "Notification pipe not initialized" unless fd

        @io = IO.for_fd(fd, autoclose: false)
      end

      def wait(timeout: 1.0)
        IO.select([@io], nil, nil, timeout)
      end

      def signal
        # C side signals the pipe — Ruby doesn't need to
      end

      def close
        @io = nil
      end
    end
  end
end
