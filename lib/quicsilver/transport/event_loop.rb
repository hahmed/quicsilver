# frozen_string_literal: true

module Quicsilver
  module Transport
    # Two threads: one drives MsQuic, one delivers its events to Ruby.
    #
    # The poll thread runs Quicsilver.poll, which releases the GVL for the
    # whole MsQuic iteration: decryption, loss recovery, stream reassembly and
    # the callbacks that queue events for Ruby all happen without the lock.
    # It is always a Thread; MsQuic needs one, and it never touches Ruby.
    #
    # The dispatcher delivers queued events, in order, to Server.handle_stream
    # or Client#handle_stream_event. It takes one of two shapes:
    #
    # - Without a fiber scheduler, a Thread that waits on the queue's condvar
    #   without the GVL. This is the thread-pool server.
    # - Under a fiber scheduler (Falcon, or any Async reactor), a Fiber on the
    #   scheduler's own thread that waits on Quicsilver.events_io, the fd the
    #   poll thread signals when the queue goes from empty to non-empty. No
    #   extra thread, and events are delivered on the thread the application's
    #   fibers run on. IO#wait_readable goes through whatever scheduler is
    #   installed, so this depends on no particular one.
    #
    # Event order is preserved either way: the queue is FIFO and there is one
    # consumer.
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
          @dispatcher = Fiber.scheduler ? start_fiber_dispatcher : start_thread_dispatcher
          @thread = Thread.new do
            Thread.current.name = "quicsilver-poll"
            Quicsilver.poll while @running
          end
        end
      end

      # Stop the poll thread first so nothing else is queued, then close the
      # queue so the dispatcher exits once it has delivered what is there.
      # Closing also signals events_io, so a fiber waiting on it wakes.
      def stop
        @running = false
        Quicsilver.wake
        @thread&.join(2)
        Quicsilver.close_event_queue
        @dispatcher.join(2) if @dispatcher.is_a?(Thread)
      end

      def join
        @thread&.join
      end

      private

      def start_thread_dispatcher
        Thread.new do
          Thread.current.name = "quicsilver-dispatch"
          loop do
            delivered = Quicsilver.dispatch_events(DISPATCH_BATCH, DISPATCH_WAIT_MS)
            break if delivered.nil? # queue closed and drained
          end
        end
      end

      # Drain the signal before dispatching, so a wakeup that lands during
      # dispatch is not consumed unseen; dispatch until the queue is empty,
      # since the signal only fires on the empty-to-non-empty edge; then wait.
      # A stale signal costs one spurious pass, never a lost one.
      def start_fiber_dispatcher
        io = Quicsilver.events_io
        Fiber.schedule do
          loop do
            Quicsilver.drain_events_signal
            delivered = Quicsilver.dispatch_events(DISPATCH_BATCH, 0)
            break if delivered.nil?
            next if delivered.positive?

            io.wait_readable
          end
        end
      end
    end
  end

  def self.event_loop
    @event_loop ||= Transport::EventLoop.new.tap(&:start)
  end

  # The read end of the event-queue signal, as an IO that does not own the
  # descriptor. Readable when events are queued or the queue is closed.
  def self.events_io
    @events_io ||= IO.for_fd(events_signal_fd, autoclose: false)
  end
end
