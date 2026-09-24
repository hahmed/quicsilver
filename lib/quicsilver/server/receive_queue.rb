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

      def available_bytes
        @mutex.synchronize { @chunks < @chunk_limit ? @byte_limit - @bytes : 0 }
      end

      def release_capacity_to(&callback)
        capacity = @mutex.synchronize do
          return if @queue.closed? || @release_capacity

          @release_capacity = callback
          [@byte_limit - @bytes, @chunk_limit - @chunks]
        end
        callback.call(*capacity)
      end

      def pop
        entry = @queue.pop
        return unless entry

        data, bytes, generation = entry
        release_capacity = @mutex.synchronize do
          # A concurrent discard already released entries from the old queue.
          if generation == @generation
            @bytes -= bytes
            @chunks -= 1
            @release_capacity unless @queue.closed?
          end
        end
        release_capacity&.call(bytes, 1)
        data
      end

      def clear
        @mutex.synchronize do
          # Writable clears only when discarding input; prevent a racing push
          # between its clear and close calls.
          @release_capacity = nil
          @queue.close
          @queue.clear
          @generation += 1
          @bytes = @chunks = 0
        end
        self
      end

      def close
        @mutex.synchronize do
          @release_capacity = nil
          @queue.close
        end
        self
      end

      def closed? = @queue.closed?
      def empty? = @queue.empty?
    end
  end
end
