# frozen_string_literal: true

require_relative "../test_helper"

class WaitTimeTest < Minitest::Test
  def setup
    @wait_time = Quicsilver::Server::WaitTime.new(window: 8)
  end

  def test_starts_empty
    assert @wait_time.empty?
    assert_equal 0, @wait_time.count
  end

  def test_percentiles_are_zero_before_any_samples
    assert_equal 0.0, @wait_time.p50
    assert_equal 0.0, @wait_time.p99
    assert_equal 0.0, @wait_time.max
  end

  def test_records_a_sample
    @wait_time.record(0.1)

    refute @wait_time.empty?
    assert_equal 1, @wait_time.count
    assert_in_delta 0.1, @wait_time.p50, 0.0001
  end

  def test_percentiles_across_samples
    [0.01, 0.02, 0.03, 0.04].each { |s| @wait_time.record(s) }

    assert_in_delta 0.025, @wait_time.p50, 0.0001
    assert_in_delta 0.04, @wait_time.max, 0.0001
  end

  def test_p99_tracks_the_slow_tail
    9.times { @wait_time.record(0.001) }
    @wait_time.record(1.0)

    assert_operator @wait_time.p50, :<, 0.01
    assert_operator @wait_time.p99, :>, 0.5,
      "a single slow sample must show up in p99"
  end

  # The ring buffer must forget old samples, otherwise a burst an hour ago
  # would keep the server looking saturated.
  def test_window_discards_oldest_samples
    8.times { @wait_time.record(5.0) }
    assert_in_delta 5.0, @wait_time.p50, 0.0001

    8.times { @wait_time.record(0.001) }

    assert_equal 8, @wait_time.count
    assert_in_delta 0.001, @wait_time.p50, 0.0001
    assert_in_delta 0.001, @wait_time.max, 0.0001
  end

  def test_record_since_measures_elapsed_time
    started = Quicsilver::Server::WaitTime.now
    sleep 0.02
    @wait_time.record_since(started)

    assert_operator @wait_time.max, :>=, 0.02
    assert_operator @wait_time.max, :<, 1.0
  end

  def test_now_is_monotonic
    first = Quicsilver::Server::WaitTime.now
    second = Quicsilver::Server::WaitTime.now

    assert_operator second, :>=, first
  end

  def test_reset_clears_samples
    4.times { @wait_time.record(1.0) }
    @wait_time.reset

    assert @wait_time.empty?
    assert_equal 0.0, @wait_time.p99
  end

  def test_to_h_reports_milliseconds
    @wait_time.record(0.25)
    summary = @wait_time.to_h

    assert_equal 1, summary["samples"]
    assert_in_delta 250.0, summary["p50_ms"], 0.01
    assert_in_delta 250.0, summary["max_ms"], 0.01
  end

  def test_concurrent_recording_is_safe
    wait_time = Quicsilver::Server::WaitTime.new(window: 1024)

    threads = 4.times.map do
      Thread.new { 100.times { wait_time.record(0.01) } }
    end
    threads.each(&:join)

    assert_equal 400, wait_time.count
  end
end
