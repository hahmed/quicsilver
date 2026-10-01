#!/usr/bin/env ruby
# frozen_string_literal: true

# Head-of-line blocking, measured on a damaged link.
#
# HTTP/2 multiplexes streams over one TCP connection, and TCP owes the
# application one ordered byte stream, so a lost packet stalls every stream
# sharing that connection. HTTP/3 scopes ordering to the stream, so a lost
# packet stalls only the streams whose data it carried. RFC 9114 1.1 puts it
# as: "because the parallel nature of HTTP/2's multiplexing is not visible to
# TCP's loss recovery mechanisms, a lost or reordered packet causes all active
# transactions to experience a stall regardless of whether that transaction was
# directly impacted by the lost packet."
#
# That is the central claim of HTTP/3, and loopback cannot show it, because
# loopback never drops a packet. So the packets are dropped in userspace:
#
#   client ──▶ Impair::Udp (drops 1 in N) ──▶ Quicsilver
#
# Kernel shaping was tried first and abandoned. macOS dummynet does not shape
# the loopback interface: pings through a 3% pipe reported 0.0% loss, so the
# experiment was reporting "loss changes nothing" while dropping nothing. The
# proxy counts what it drops, and a row is only reported when the measured loss
# is close to the requested loss.
#
#   ruby benchmarks/loss.rb
#   LOSS=0,50,20,10 REQUESTS=1000 CONCURRENCY=20 ruby benchmarks/loss.rb
#
# LOSS is 1-in-N, the way MsQuic's emulated-performance runs express it, with 0
# meaning no loss. 10 is a brutal 10%; real networks are 1-in-100 or worse.
#
# Only HTTP/3 is measured here, because impairing TCP needs a stream relay that
# does not exist yet. Until it does, the honest comparison is this table's own
# shape as loss rises, not a number against Falcon.

ENV["RUNS"] ||= "1"
require_relative "compare"
require "impair"

LOSS_RATES = ENV.fetch("LOSS", "0,100,50,20,10").split(",").map { |value| Integer(value) }
REORDER = Integer(ENV.fetch("REORDER", "0"))
# One-way delay in milliseconds, so RTT is twice this. Loss without a round
# trip understates itself: loopback retransmits in microseconds, and the cost
# of a retransmission is one RTT. This is the axis that makes loss hurt.
DELAY_MS = Float(ENV.fetch("DELAY_MS", "0"))
SEED = Integer(ENV.fetch("SEED", "1234"))

# The proxy sits on the same address family the server binds, so that the
# client can reach it by the name on the certificate.
def with_impaired_quicsilver(loss:)
  server_port = free_port
  config = Quicsilver::Transport::Configuration.new(
    AUTHORITY.certificate_path, AUTHORITY.key_path
  )
  server = Quicsilver::Server.new(server_port, address: "::1", app: APP, server_configuration: config)
  Quicsilver::Server.instance = server
  thread = Thread.new { server.start }
  sleep 0.05 until server.running?

  proxy = Impair::Udp.new(
    host: "::1", target_host: "::1", target_port: server_port,
    loss: loss, reorder: REORDER, delay: DELAY_MS / 1000.0, seed: SEED
  ).start

  begin
    result = yield proxy.port
    [result, proxy.stop]
  ensure
    server.stop
    thread.join(5)
  end
end

rows = []

puts "Head-of-line blocking under induced packet loss"
puts "#{REQUESTS} requests, #{CONCURRENCY} in flight, HTTP/3 through a userspace impairment proxy"
puts "loss is 1-in-N applied in both directions, seed #{SEED}"
puts "one-way delay #{DELAY_MS}ms, so about #{(DELAY_MS * 2).round}ms round trip" if DELAY_MS.positive?
puts

# Repeats per row, because this server's own throughput varies enough between
# runs to swallow the effect being measured. A single run once showed higher
# throughput at 9% loss than at none, which is not a finding about loss.
REPEATS = Integer(ENV.fetch("REPEATS", "3"))

def median_of(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end

LOSS_RATES.each do |loss|
  attempts = REPEATS.times.filter_map do
    result, counts = with_impaired_quicsilver(loss: loss) { |port| measure_quicsilver(port) }

    # Report what the link actually did, not what was asked for. A row where
    # the impairment did not apply is worse than no row.
    expected = loss.zero? ? 0.0 : 1.0 / loss
    if loss.positive? && counts.loss_rate < expected / 2
      warn format("  1-in-%d: proxy dropped only %.2f%%, discarding", loss, counts.loss_rate * 100)
      next
    end

    stats = Benchmarks.stats(result.times)
    {rps: result.rps, p50: stats[:p50], p95: stats[:p95], p99: stats[:p99],
     failed: result.failed, measured: counts.loss_rate}
  rescue StandardError => error
    warn "1-in-#{loss} failed: #{error.class}: #{error.message}"
    warn error.backtrace.first(3).join("\n") if ENV["DEBUG"]
    nil
  end
  next if attempts.empty?

  rows << [loss, attempts]
end

puts format("%-10s %8s %9s %9s %9s %9s %8s %15s",
  "loss", "measured", "Req/s", "p50", "p95", "p99", "Failed", "Req/s range")
puts "-" * 86
rows.each do |(loss, attempts)|
  rates = attempts.map { |a| a[:rps] }
  puts format("%-10s %7.2f%% %9.0f %7.2fms %7.2fms %7.2fms %8d %15s",
    loss.zero? ? "none" : "1-in-#{loss}",
    median_of(attempts.map { |a| a[:measured] }) * 100,
    median_of(rates),
    median_of(attempts.map { |a| a[:p50] }),
    median_of(attempts.map { |a| a[:p95] }),
    median_of(attempts.map { |a| a[:p99] }),
    attempts.sum { |a| a[:failed] },
    (rates.length > 1 ? format("%.0f-%.0f", rates.min, rates.max) : "single"))
end

puts
puts "The proxy is in the path for every row, including the first, so the"
puts "no-loss row is the baseline rather than a direct connection."
puts "Loss is applied to both directions, so a request and its response each"
puts "face the dice, and the measured rate is roughly twice the per-packet rate."
