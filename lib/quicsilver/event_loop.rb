# frozen_string_literal: true

module Quicsilver
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
      @thread&.join(2)
    end

    def join
      @thread&.join
    end
  end

  def self.event_loop
    @event_loop ||= EventLoop.new.tap(&:start)
  end
end
