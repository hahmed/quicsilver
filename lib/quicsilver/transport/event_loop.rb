# frozen_string_literal: true

module Quicsilver
  module Transport
    # Drives event processing via the EventBridge.
    #
    # MsQuic fires callbacks on its own thread pool → ring buffer.
    # EventLoop watches the notification pipe → drains buffer to Ruby.
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
          @thread = Thread.new { run_loop }
        end
      end

      def stop
        @running = false
        Quicsilver.wake  # signal pipe to unblock IO.select
        @thread&.join(2)
        @bridge&.close
        @bridge = nil
      end

      def join
        @thread&.join
      end

      private

      def run_loop
        while @running
          # Wait for MsQuic to signal events (releases GVL)
          @bridge.wait(timeout: 1.0)

          # Drain buffered events to Ruby (has GVL)
          Quicsilver.drain_queue
        end
      end
    end
  end

  def self.event_loop
    @event_loop ||= Transport::EventLoop.new.tap(&:start)
  end
end
