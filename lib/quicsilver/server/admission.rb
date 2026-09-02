# frozen_string_literal: true

require_relative "wait_time"

module Quicsilver
  class Server
    # Decides whether a request may be admitted, and says why when it may not.
    #
    # Admission is graduated rather than a cliff:
    #
    #   1. queue has room and waits are short  -> accept
    #   2. waits are climbing                  -> narrow the stream window, so
    #                                             the peer slows down before we
    #                                             have to refuse anything
    #   3. queue full, or waits over budget    -> shed deliberately
    #
    # Depth alone cannot distinguish a burst from saturation. A short burst
    # should be absorbed by the queue: refusing it wastes work that would have
    # completed, and the client pays a retry for nothing. Sustained overload
    # should be refused promptly, because a queue that takes longer to drain
    # than the client's timeout produces responses nobody is listening to.
    #
    # Wait time is what separates those two cases, so it is the primary signal
    # here and depth is the backstop.
    class Admission
      # Requests waiting longer than this are considered saturation rather than
      # a burst. Matches the Fantail default.
      DEFAULT_WAIT_LIMIT = 0.25

      # Fraction of the wait limit at which we start asking peers to slow down.
      DEFAULT_PRESSURE_RATIO = 0.5

      Decision = Struct.new(:outcome, :reason, :status, :retry_after) do
        def accept? = outcome == :accept
        def shed? = outcome == :shed
      end

      ACCEPT = Decision.new(:accept, nil, nil, nil).freeze

      attr_reader :wait_limit, :wait_time, :shed_status, :retry_after

      def initialize(scheduler:, max_queue_size:, wait_limit: DEFAULT_WAIT_LIMIT,
                     shed_status: 503, retry_after: 1, pressure_ratio: DEFAULT_PRESSURE_RATIO)
        @scheduler = scheduler
        @max_queue_size = max_queue_size
        @wait_limit = wait_limit
        @shed_status = shed_status
        @retry_after = retry_after
        @pressure_ratio = pressure_ratio
        @wait_time = scheduler.respond_to?(:wait_time) ? scheduler.wait_time : WaitTime.new
        @shed_count = 0
        @mutex = Mutex.new
      end

      # Returns a Decision. Callers must not register any request state before
      # asking, so that a shed has nothing to unwind.
      def decide
        if @scheduler.full?
          shed(:queue_full)
        elsif over_wait_limit?
          shed(:wait_limit)
        else
          ACCEPT
        end
      end

      def over_wait_limit?
        return false if @wait_limit.nil? || @wait_time.empty?

        @wait_time.p99 > @wait_limit
      end

      # True once waits are long enough that peers should be asked to slow down,
      # but before anything needs refusing.
      def under_pressure?
        return false if @wait_limit.nil? || @wait_time.empty?

        @wait_time.p99 > (@wait_limit * @pressure_ratio)
      end

      # 0.0 (idle) to 1.0 (at or over the wait budget), whichever of queue depth
      # or wait time is worse.
      def pressure
        [depth_pressure, wait_pressure].max.clamp(0.0, 1.0)
      end

      def shed_count
        @mutex.synchronize { @shed_count }
      end

      def to_h
        {
          "pressure" => pressure.round(3),
          "under_pressure" => under_pressure?,
          "wait_limit_ms" => @wait_limit ? (@wait_limit * 1000).round(2) : nil,
          "over_wait_limit" => over_wait_limit?,
          "shed_count" => shed_count,
          "wait" => @wait_time.to_h
        }
      end

      private

      def shed(reason)
        @mutex.synchronize { @shed_count += 1 }
        Decision.new(:shed, reason, @shed_status, @retry_after).freeze
      end

      def depth_pressure
        return 0.0 if @max_queue_size.nil? || @max_queue_size.zero?

        @scheduler.pending.to_f / @max_queue_size
      end

      def wait_pressure
        return 0.0 if @wait_limit.nil? || @wait_limit.zero? || @wait_time.empty?

        @wait_time.p99 / @wait_limit
      end
    end
  end
end
