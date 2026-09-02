# frozen_string_literal: true

require_relative "../test_helper"

class AdmissionTest < Minitest::Test
  # Minimal scheduler stand-in: tests drive depth and wait time directly.
  class FakeScheduler
    attr_reader :wait_time
    attr_accessor :pending, :full

    def initialize(pending: 0, full: false)
      @pending = pending
      @full = full
      @wait_time = Quicsilver::Server::WaitTime.new
    end

    def full? = @full
  end

  def setup
    @scheduler = FakeScheduler.new
    @admission = build_admission
  end

  # === accepting ===

  def test_accepts_when_idle
    assert @admission.decide.accept?
  end

  def test_accepts_while_waits_are_short
    5.times { @scheduler.wait_time.record(0.01) }

    assert @admission.decide.accept?
  end

  # A burst is work that queues briefly and still completes. Refusing it wastes
  # work that would have succeeded, so depth on its own must not shed.
  def test_absorbs_a_burst_that_has_depth_but_short_waits
    @scheduler.pending = 15
    10.times { @scheduler.wait_time.record(0.005) }

    assert @admission.decide.accept?,
      "queued work with short waits is a burst, not saturation"
  end

  # === shedding ===

  def test_sheds_when_queue_is_full
    @scheduler.full = true
    decision = @admission.decide

    assert decision.shed?
    assert_equal :queue_full, decision.reason
    assert_equal 503, decision.status
    assert_equal 1, decision.retry_after
  end

  # Sustained overload: the queue would take longer to drain than the client
  # will wait, so completing the work produces responses nobody reads.
  def test_sheds_when_waits_exceed_the_limit
    10.times { @scheduler.wait_time.record(0.9) }
    decision = @admission.decide

    assert decision.shed?
    assert_equal :wait_limit, decision.reason
  end

  def test_queue_full_takes_precedence_over_wait_limit
    @scheduler.full = true
    10.times { @scheduler.wait_time.record(0.9) }

    assert_equal :queue_full, @admission.decide.reason
  end

  def test_counts_sheds
    @scheduler.full = true
    3.times { @admission.decide }

    assert_equal 3, @admission.shed_count
  end

  def test_accepting_does_not_count_as_a_shed
    5.times { @admission.decide }

    assert_equal 0, @admission.shed_count
  end

  def test_nil_wait_limit_disables_wait_based_shedding
    admission = build_admission(wait_limit: nil)
    10.times { @scheduler.wait_time.record(30.0) }

    assert admission.decide.accept?
    refute admission.over_wait_limit?
  end

  def test_shed_status_is_configurable
    admission = build_admission(shed_status: 429, retry_after: 5)
    @scheduler.full = true
    decision = admission.decide

    assert_equal 429, decision.status
    assert_equal 5, decision.retry_after
  end

  # === pressure, the signal before refusal ===

  def test_not_under_pressure_when_idle
    refute @admission.under_pressure?
  end

  # The point of a pressure signal is to act before shedding starts: ask peers
  # to slow down while everything is still being served.
  def test_under_pressure_before_shedding_begins
    10.times { @scheduler.wait_time.record(0.15) }

    assert @admission.under_pressure?,
      "should signal pressure at half the wait budget"
    assert @admission.decide.accept?,
      "pressure must not yet mean refusal"
  end

  def test_pressure_rises_with_queue_depth
    idle = @admission.pressure
    @scheduler.pending = 10

    assert_operator @admission.pressure, :>, idle
  end

  def test_pressure_rises_with_wait_time
    idle = @admission.pressure
    10.times { @scheduler.wait_time.record(0.2) }

    assert_operator @admission.pressure, :>, idle
  end

  def test_pressure_is_clamped_to_one
    @scheduler.pending = 10_000
    10.times { @scheduler.wait_time.record(60.0) }

    assert_equal 1.0, @admission.pressure
  end

  def test_pressure_takes_the_worse_of_depth_and_wait
    @scheduler.pending = 0
    10.times { @scheduler.wait_time.record(0.25) }

    assert_in_delta 1.0, @admission.pressure, 0.01,
      "an empty queue must not mask a long wait"
  end

  # === reporting ===

  def test_to_h_exposes_the_signals
    10.times { @scheduler.wait_time.record(0.05) }
    summary = @admission.to_h

    assert_equal 250.0, summary["wait_limit_ms"]
    refute summary["over_wait_limit"]
    assert_equal 0, summary["shed_count"]
    assert_equal 10, summary.dig("wait", "samples")
  end

  def test_falls_back_to_its_own_recorder_when_scheduler_has_none
    bare = Class.new do
      def full? = false
      def pending = 0
    end.new

    admission = Quicsilver::Server::Admission.new(scheduler: bare, max_queue_size: 20)

    assert admission.decide.accept?
    assert_equal 0.0, admission.pressure
  end

  private

  def build_admission(**options)
    Quicsilver::Server::Admission.new(
      scheduler: @scheduler,
      max_queue_size: 20,
      **options
    )
  end
end
