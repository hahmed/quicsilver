# frozen_string_literal: true

module Quicsilver
  module Transport
    # Drives MsQuic's event loop on a background thread.
    #
    # Uses MsQuic's custom execution context — all callbacks fire on
    # this thread during Quicsilver.poll. The poll call releases the
    # GVL during kevent/epoll_wait so other Ruby threads run freely.
    #
    # For fiber mode (Async/Falcon), the plan is to switch MsQuic to
    # its default thread pool and use a notification pipe + io-event
    # selector. See autoresearch.ideas.md for the design.
    #
    class EventLoop
      def initialize
        @running = false
        @thread = nil
        @mutex = Mutex.new
      end

      def start
        @mutex.synchronize do
          return if @running

          @running = true
          @thread = Thread.new do
            Quicsilver.poll while @running
          end
        end
      end

      def stop
        @running = false
        Quicsilver.wake
        @thread&.join(2)
      end

      def join
        @thread&.join
      end
    end
  end

  def self.event_loop
    @event_loop ||= Transport::EventLoop.new.tap(&:start)
  end
end
