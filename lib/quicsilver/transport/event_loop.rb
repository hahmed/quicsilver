# frozen_string_literal: true

module Quicsilver
  module Transport
    # Drives MsQuic's event loop on a background thread.
    #
    # With custom execution context (current):
    #   poll() drives MsQuic via kevent/epoll (releases GVL during wait).
    #   Callbacks fire during poll → write to ring buffer.
    #   poll() drains the buffer after completions.
    #
    # With MsQuic thread pool (future Option A):
    #   No poll() — MsQuic drives itself on its own threads.
    #   bridge.wait on notification pipe (releases GVL).
    #   drain_queue processes buffered events.
    #
    class EventLoop
      attr_reader :bridge

      def initialize
        @running = false
        @thread = nil
        @mutex = Mutex.new
        @bridge = nil
      end

      def start
        @mutex.synchronize do
          return if @running

          @bridge = PipeEventBridge.new
          @running = true
          @thread = Thread.new do
            # poll() handles everything: kevent wait + completions + drain
            Quicsilver.poll while @running
          end
        end
      end

      def stop
        @running = false
        Quicsilver.wake
        @thread&.join(2)
        @bridge&.close
        @bridge = nil
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
