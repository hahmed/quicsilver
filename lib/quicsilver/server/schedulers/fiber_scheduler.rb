# frozen_string_literal: true

require_relative "../scheduler"
require_relative "../wait_time"

module Quicsilver
  class Server
    module Schedulers
      # Fiber-based scheduler — uses Async::Queue for cooperative scheduling.
      # Expects to be running inside an Async reactor (e.g. Falcon provides one).
      # Requires the async gem.
      class FiberScheduler < Scheduler
        attr_reader :wait_time

        def initialize(concurrency:, max_queue_size:, &handler)
          require "async"
          require "async/queue"
          require "async/barrier"

          @concurrency = concurrency
          @max_queue_size = max_queue_size
          @handler = handler
          @queue = Async::Queue.new
          @running = false
          @barrier = nil
          @wait_time = WaitTime.new
        end

        def enqueue(work)
          @queue.enqueue([WaitTime.now, work])
        end

        def full?
          @queue.size >= @max_queue_size
        end

        def pending
          @queue.size
        end

        # Spawn fiber workers inside the current Async reactor.
        # Caller must already be inside Async do (e.g. Falcon).
        def start
          @running = true
          @barrier = Async::Barrier.new

          @concurrency.times do
            @barrier.async do
              while @running
                item = @queue.dequeue
                break if item == :shutdown

                enqueued_at, work = item
                @wait_time.record_since(enqueued_at)
                @handler.call(work)
              end
            end
          end
        end

        def drain(timeout: 5)
          deadline = Time.now + timeout
          while @queue.size > 0 && Time.now < deadline
            sleep 0.05
          end
        end

        def stop
          @running = false
          @concurrency.times { @queue.enqueue(:shutdown) }
          @barrier&.wait
        end
      end
    end
  end
end
