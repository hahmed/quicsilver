# frozen_string_literal: true

module Quicsilver
  class Server
    # Base class for work schedulers.
    #
    # A scheduler controls how incoming request work units are executed —
    # via threads, fibers, or any other concurrency model. Subclasses
    # implement the delivery mechanism.
    #
    # Usage:
    #   scheduler = ThreadScheduler.new(size: 10, max_queue_size: 100, &handler)
    #   scheduler.start               # start workers
    #   scheduler.enqueue(work)        # schedule a work unit
    #   scheduler.drain(timeout: 5)    # wait for queue to empty
    #   scheduler.stop                 # shut down workers
    #
    class Scheduler
      # Schedule a work unit for execution.
      def enqueue(work)
        raise NotImplementedError
      end

      # Is the work queue at capacity?
      def full?
        raise NotImplementedError
      end

      # Number of pending work units.
      def pending
        raise NotImplementedError
      end

      # Wait for the queue to empty.
      def drain(timeout: 5)
        raise NotImplementedError
      end

      # Start processing work units.
      def start
        raise NotImplementedError
      end

      # Shut down workers.
      def stop
        raise NotImplementedError
      end
    end
  end
end
