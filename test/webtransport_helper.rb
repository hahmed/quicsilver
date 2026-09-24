# frozen_string_literal: true

require "test_helper"

# Shared helpers for WebTransport tests, so a test body reads as the behaviour
# it is asserting rather than as setup and thread plumbing.
#
# Reading a WebTransport stream blocks, so every read here takes a deadline.
# Without one a delivery bug hangs the suite instead of failing it.
module WebTransportHelpers
  # Read at least `bytes` from a stream.
  def drain_stream(stream, bytes, timeout: 3)
    read_with_deadline(timeout, "draining #{bytes} bytes from stream #{stream.stream_id}") do
      buffer = "".b
      buffer << stream.read while buffer.bytesize < bytes
      buffer
    end
  end

  # Read until the peer's FIN, so a suffix that never arrives fails the test.
  def drain_to_eof(stream, timeout: 15)
    read_with_deadline(timeout, "reading stream #{stream.stream_id} to EOF") do
      buffer = "".b
      while (chunk = stream.read)
        buffer << chunk
      end
      buffer
    end
  end

  # Accumulate up to `bytes` from a queue another thread is reading into.
  # Delivery may be split across chunks, so a single pop is not enough.
  def collect(chunks, bytes, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    buffer = "".b
    while buffer.bytesize < bytes
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0

      chunk = chunks.pop(timeout: remaining)
      break if chunk.nil?

      buffer << chunk
    end
    buffer
  end

  private

  def read_with_deadline(timeout, description)
    reader = Thread.new { yield }
    reader.report_on_exception = false
    assert reader.join(timeout), "Timed out #{description}"
    reader.value
  ensure
    reader&.kill
    reader&.join(timeout)
  end
end
