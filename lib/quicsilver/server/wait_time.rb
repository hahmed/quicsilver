# frozen_string_literal: true

module Quicsilver
  class Server
    # Rolling record of how long work waited in the queue before a worker
    # picked it up.
    #
    # Queue depth alone cannot tell a burst from saturation: a depth of 20 is
    # harmless at 5ms per request and fatal at 2s per request. Wait time can,
    # which makes it the signal admission decisions should be based on.
    #
    # Fixed-size ring buffer so recording stays allocation-free on the hot path.
    class WaitTime
      DEFAULT_WINDOW = 256

      def initialize(window: DEFAULT_WINDOW)
        @window = window
        @samples = Array.new(window, 0.0)
        @count = 0
        @index = 0
        @mutex = Mutex.new
      end

      # Monotonic timestamp for stamping work as it is enqueued.
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def record(seconds)
        @mutex.synchronize do
          @samples[@index] = seconds
          @index = (@index + 1) % @window
          @count += 1 if @count < @window
        end
      end

      def record_since(enqueued_at)
        record(self.class.now - enqueued_at)
      end

      def empty?
        @mutex.synchronize { @count.zero? }
      end

      def count
        @mutex.synchronize { @count }
      end

      # Seconds. Returns 0.0 until at least one sample has been recorded.
      def percentile(rank)
        sorted = sorted_samples
        return 0.0 if sorted.empty?

        position = (rank / 100.0) * (sorted.length - 1)
        lower = sorted[position.floor]
        upper = sorted[position.ceil]
        lower + ((upper - lower) * (position - position.floor))
      end

      def p50 = percentile(50)
      def p99 = percentile(99)

      def max
        sorted_samples.last || 0.0
      end

      def reset
        @mutex.synchronize do
          @samples.fill(0.0)
          @count = 0
          @index = 0
        end
      end

      def to_h
        {
          "samples" => count,
          "p50_ms" => ms(p50),
          "p99_ms" => ms(p99),
          "max_ms" => ms(max)
        }
      end

      private

      def sorted_samples
        @mutex.synchronize do
          @count.zero? ? [] : @samples.first(@count).sort
        end
      end

      def ms(seconds)
        (seconds * 1000).round(2)
      end
    end
  end
end
