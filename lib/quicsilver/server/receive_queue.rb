# frozen_string_literal: true

module Quicsilver
  class Server
    # Nonblocking admission for Body::Writable; only the consumer may wait.
    class ReceiveQueue
      class Full < StandardError; end

      def self.validate_limits(bytes, chunks)
        [bytes, chunks].each do |limit|
          raise ArgumentError, "Receive limits must be positive integers" unless limit.is_a?(Integer) && limit.positive?
        end
      end

      def initialize(bytes:, chunks:)
        self.class.validate_limits(bytes, chunks)
        @byte_limit = bytes
        @chunk_limit = chunks
        @queue = Thread::Queue.new
        @mutex = Mutex.new
        @bytes = 0
        @chunks = 0
        @generation = 0
      end

      def push(data)
        @mutex.synchronize do
          raise ClosedQueueError if @queue.closed?
          raise Full if data.bytesize > @byte_limit - @bytes || @chunks >= @chunk_limit

          @queue.push([data, data.bytesize, @generation])
          @bytes += data.bytesize
          @chunks += 1
        end
        self
      end

      def pop
        entry = @queue.pop
        return unless entry

        data, bytes, generation = entry
        @mutex.synchronize do
          # A concurrent discard already released entries from the old queue.
          if generation == @generation
            @bytes -= bytes
            @chunks -= 1
          end
        end
        data
      end

      def clear
        @mutex.synchronize do
          # Writable clears only when discarding input; prevent a racing push
          # between its clear and close calls.
          @queue.close
          @queue.clear
          @generation += 1
          @bytes = @chunks = 0
        end
        self
      end

      def close
        @mutex.synchronize { @queue.close }
        self
      end

      def closed? = @queue.closed?
      def empty? = @queue.empty?
    end
  end
end
