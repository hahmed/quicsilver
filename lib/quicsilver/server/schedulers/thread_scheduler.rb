# frozen_string_literal: true

require_relative "../scheduler"
require_relative "../wait_time"

module Quicsilver
  class Server
    module Schedulers
      # Thread-based scheduler — uses a thread pool with Thread::Queue.
      class ThreadScheduler < Scheduler
        attr_reader :wait_time

        def initialize(concurrency:, max_queue_size:, &handler)
          @size = concurrency
          @max_queue_size = max_queue_size
          @handler = handler
          @queue = Queue.new
          @threads = []
          @mutex = Mutex.new
          @wait_time = WaitTime.new
        end

        # Work is stamped on the way in so the worker can record how long it
        # waited. Depth tells you how much is queued; this tells you whether
        # that depth actually matters.
        def enqueue(work)
          @queue.push([WaitTime.now, work])
        end

        def full?
          @queue.size >= @max_queue_size
        end

        def pending
          @queue.size
        end

        def start
          @size.times do
            thread = Thread.new do
              while (item = @queue.pop)
                break if item == :shutdown

                enqueued_at, work = item
                @wait_time.record_since(enqueued_at)
                @handler.call(work)
              end
            end
            @mutex.synchronize { @threads << thread }
          end
        end

        def drain(timeout: 5)
          deadline = Time.now + timeout
          while @queue.size > 0 && Time.now < deadline
            sleep 0.05
          end
        end

        def stop
          @size.times { @queue.push(:shutdown) }
          @mutex.synchronize do
            @threads.each { |t| t.join(2) }
            @threads.each { |t| t.raise(DrainTimeoutError, "drain timeout") if t.alive? }
            @threads.clear
          end
        end
      end
    end
  end
end
