# frozen_string_literal: true

module Quicsilver
  module Transport
    # Two threads: one drives MsQuic, one delivers its events to Ruby.
    #
    # The poll thread runs Quicsilver.poll, which releases the GVL for the
    # whole MsQuic iteration: decryption, loss recovery, stream reassembly and
    # the callbacks that queue events for Ruby all happen without the lock.
    # The dispatcher thread runs Quicsilver.dispatch_events, which waits on
    # that queue without the GVL, then takes it to call Server.handle_stream
    # (or Client#handle_stream_event) for each event in order.
    #
    # Before, a single thread did both, and every byte MsQuic processed was
    # processed while holding the GVL, because the callback at the end of it
    # called into Ruby. Splitting them lets the datapath run in parallel with
    # the dispatcher and the worker pool.
    #
    # Event order is preserved: the queue is FIFO and there is one consumer.
    class EventLoop
      # Events delivered per GVL hold. Bounds how long a batch runs; the
      # dispatcher yields early only when the server's admission queue is
      # under pressure (Server#enqueue_work). QUICSILVER_DISPATCH_BATCH
      # overrides it for measurement.
      DISPATCH_BATCH = Integer(ENV.fetch("QUICSILVER_DISPATCH_BATCH", "64"))
      DISPATCH_WAIT_MS = 1000

      def initialize
        @running = false
        @thread = nil
        @dispatcher = nil
        @mutex = Mutex.new
      end

      def start
        @mutex.synchronize do
          return if @running

          @running = true
          Quicsilver.open_event_queue
          @dispatcher = Thread.new do
            Thread.current.name = "quicsilver-dispatch"
            loop do
              delivered = Quicsilver.dispatch_events(DISPATCH_BATCH, DISPATCH_WAIT_MS)
              break if delivered.nil? # queue closed and drained
            end
          end
          @thread = Thread.new do
            Thread.current.name = "quicsilver-poll"
            Quicsilver.poll while @running
          end
        end
      end

      # Stop the poll thread first so nothing else is queued, then close the
      # queue so the dispatcher exits once it has delivered what is there.
      def stop
        @running = false
        Quicsilver.wake
        @thread&.join(2)
        Quicsilver.close_event_queue
        @dispatcher&.join(2)
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
