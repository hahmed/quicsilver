# frozen_string_literal: true

module Quicsilver
  module Transport
    # Bounded blocking receive queue for unreliable datagrams.
    #
    # Unlike stream data, datagrams are allowed to drop. Mature QUIC stacks bound
    # datagram queues; this queue drops new datagrams when full and tracks drops.
    class DatagramQueue
      CLOSED = Object.new.freeze
      DEFAULT_MAX_LENGTH = 128

      attr_reader :dropped

      def initialize(max_length: DEFAULT_MAX_LENGTH)
        @max_length = max_length
        @queue = Queue.new
        @length = 0
        @byte_size = 0
        @dropped = 0
        @closed = false
        @mutex = Mutex.new
      end

      def push(data)
        data = data.to_s.b

        @mutex.synchronize do
          return false if @closed

          if @length >= @max_length
            @dropped += 1
            return false
          end

          @length += 1
          @byte_size += data.bytesize
          @queue << data
          true
        end
      end

      def pop
        item = @queue.pop
        return nil if item.equal?(CLOSED)

        @mutex.synchronize do
          @length -= 1
          @byte_size -= item.bytesize
        end

        item
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

      def length
        @mutex.synchronize { @length }
      end

      def byte_size
        @mutex.synchronize { @byte_size }
      end

      def max_length
        @max_length
      end
    end
  end
end
