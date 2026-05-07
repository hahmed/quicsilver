# frozen_string_literal: true

require "protocol/http/body/writable"

module Quicsilver
  module Protocol
    # A streaming request body backed by Protocol::HTTP::Body::Writable.
    #
    # QUIC RECEIVE events push chunks via {write}, while the application
    # reads them via {read}. This enables concurrent streaming — the app
    # can start processing before the full body arrives.
    #
    # Follows the protocol-http Body::Writable contract:
    # - write(chunk) — called by the QUIC transport on RECEIVE events
    # - close_write  — called on RECEIVE_FIN to signal end of body
    # - read         — called by the application (blocks until data available)
    # - close        — called to abort (e.g., stream reset)
    #
    # Optional features:
    # - Back-pressure via Thread::SizedQueue (bounded buffer)
    # - Read timeout for slow client protection
    #
    class StreamInput < ::Protocol::HTTP::Body::Writable
      class ReadTimeout < Quicsilver::Error; end

      # @param length [Integer, nil] The content-length if known from headers.
      # @param queue_size [Integer, nil] Maximum buffered chunks for back-pressure.
      #   nil (default) = unbounded. When bounded, write blocks if queue is full,
      #   which naturally maps to QUIC flow control.
      # @param read_timeout [Numeric, nil] Seconds to wait for data before raising
      #   ReadTimeout. nil (default) = wait forever.
      def initialize(length = nil, queue_size: nil, read_timeout: nil)
        queue = if queue_size
          Thread::SizedQueue.new(queue_size)
        else
          Thread::Queue.new
        end

        super(length, queue: queue)
        @read_timeout = read_timeout
        @bytes_written = 0
      end

      # @attribute [Numeric, nil] Read timeout in seconds.
      attr_reader :read_timeout

      # Track bytes written for content-length validation.
      def write(chunk)
        @bytes_written += chunk.bytesize
        super
      end

      # Signal that no more data will be written.
      # Validates content-length if declared (RFC 9114 §4.1.2) — raises
      # MessageError if total bytes written don't match.
      def close_write(error = nil)
        if @length && @bytes_written != @length
          raise Protocol::MessageError, "Content-length mismatch: header=#{@length}, body=#{@bytes_written}"
        end
        super
      end

      # Read the next available chunk, with optional timeout.
      #
      # @returns [String | Nil] The next chunk, or nil if the body is finished.
      # @raises [ReadTimeout] If no data arrives within the timeout.
      # @raises [Exception] If the body was closed due to an error.
      def read
        if @read_timeout
          read_with_timeout
        else
          super
        end
      end

      private

      def read_with_timeout
        raise @error if @error

        # Thread::Queue#pop(timeout:) blocks efficiently (no busy-wait).
        # Returns nil on timeout OR on closed empty queue — disambiguate below.
        chunk = @queue.pop(timeout: @read_timeout)

        raise @error if @error

        # nil means either timeout or body finished (queue closed + empty).
        # If queue is closed, the body is done — return nil (EOF).
        # If queue is still open, we timed out waiting for data.
        if chunk.nil? && !@queue.closed?
          raise ReadTimeout, "No data received within #{@read_timeout}s"
        end

        chunk
      end
    end
  end
end
