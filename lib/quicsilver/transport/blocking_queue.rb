# frozen_string_literal: true

module Quicsilver
  module Transport
    # Minimal thread-safe blocking queue with close semantics.
    #
    # This backs IO-shaped APIs such as accept_stream and stream.read. It is
    # intentionally small so we can swap in an Async/fiber-aware backend later
    # without leaking Queue details into WebTransport classes.
    class BlockingQueue
      CLOSED = Object.new.freeze

      def initialize
        @queue = Queue.new
        @closed = false
        @mutex = Mutex.new
      end

      def push(item)
        @mutex.synchronize do
          return false if @closed
          @queue << item
          true
        end
      end

      def pop
        item = @queue.pop
        item.equal?(CLOSED) ? nil : item
      end

      def close
        @mutex.synchronize do
          return false if @closed
          @closed = true
          @queue << CLOSED
          true
        end
      end

      def closed?
        @closed
      end
    end
  end
end
