# frozen_string_literal: true

require "test_helper"

class ThreadSchedulerTest < Minitest::Test
  # A failing unit of work used to end the worker thread. The pool shrank for
  # the rest of the process, and Server#stop re-raised the error when it joined
  # the dead thread.
  def test_a_failing_unit_of_work_does_not_kill_the_worker
    done = Queue.new
    scheduler = build_scheduler do |work|
      raise IOError, "QUIC stream is closed" if work == :boom

      done << work
    end
    scheduler.start

    scheduler.enqueue(:boom)
    scheduler.enqueue(:after)

    assert_equal :after, done.pop(timeout: 3), "worker died on the failing work"
  ensure
    scheduler&.stop
  end

  def test_stop_does_not_raise_after_a_failing_unit_of_work
    scheduler = build_scheduler { |_work| raise IOError, "QUIC stream is closed" }
    scheduler.start
    scheduler.enqueue(:boom)
    sleep 0.1

    scheduler.stop # must not re-raise the worker's error
  end

  private

  def build_scheduler(&handler)
    Quicsilver::Server::Schedulers::ThreadScheduler.new(concurrency: 1, max_queue_size: 8, &handler)
  end
end
