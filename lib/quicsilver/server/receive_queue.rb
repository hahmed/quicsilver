# frozen_string_literal: true

module Quicsilver
  class Server
    # Nonblocking admission for Body::Writable; only the consumer may wait.
    class ReceiveQueue
      def self.validate_limits(bytes, chunks)
        [bytes, chunks].each do |limit|
          raise ArgumentError, "Receive limits must be positive integers" unless limit.is_a?(Integer) && limit.positive?
        end
      end

      # Accounting only. Every byte pushed here was sent inside a limit this
      # endpoint advertised (RFC 9000 §4.1), so there is no refusing it; the
      # receiver controls the rate by deciding when to advertise more (§4.2),
      # which is what native receive credit does. Whether being over the limit
      # means "stop granting" or "stop the stream" is the caller's policy.
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

          @queue.push([data, data.bytesize, @generation])
          @bytes += data.bytesize
          @chunks += 1
        end
        self
      end

      def over_limit?
        @mutex.synchronize { @bytes > @byte_limit || @chunks > @chunk_limit }
      end

      def available_bytes
        @mutex.synchronize { @chunks < @chunk_limit ? [@byte_limit - @bytes, 0].max : 0 }
      end

      def release_capacity_to(&callback)
        capacity = @mutex.synchronize do
          return if @queue.closed? || @release_capacity

          @release_capacity = callback
          [[@byte_limit - @bytes, 0].max, [@chunk_limit - @chunks, 0].max]
        end
        callback.call(*capacity)
      end

      def pop
        entry = @queue.pop
        return unless entry

        data, bytes, generation = entry
        grant_bytes = grant_chunks = 0
        release_capacity = @mutex.synchronize do
          # A concurrent discard already released entries from the old queue.
          if generation == @generation
            @bytes -= bytes
            @chunks -= 1
            # Grant back what was freed, capped at the capacity that is now
            # actually spare. After an oversized first receive the two differ,
            # and granting the full amount would admit another oversized one.
            grant_bytes = [bytes, @byte_limit - @bytes].min.clamp(0..)
            grant_chunks = [1, @chunk_limit - @chunks].min.clamp(0..)
            @release_capacity unless @queue.closed?
          end
        end
        release_capacity&.call(grant_bytes, grant_chunks) if grant_bytes.positive? || grant_chunks.positive?
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
