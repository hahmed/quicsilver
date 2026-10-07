#!/usr/bin/env ruby
# frozen_string_literal: true

# Quicsilver, Falcon and Puma over a link with a real round trip.
#
# This is the comparison loopback cannot give you. On localhost every protocol
# looks the same because there is no round trip to spend, and the benchmark
# measures Ruby rather than HTTP. Add a delay and the protocols start to differ
# for the reasons they were designed to.
#
# Loss is in the same currency on both sides: one in N packets costs the
# affected stream one round trip. On UDP that is a dropped datagram. On TCP the
# bytes cannot be dropped, so the stream stalls for a round trip instead, which
# is what the receiving kernel does while it waits for the retransmission. Same
# probability, same cost, and what is left over is the protocol's own
# behaviour. See Impair::Tcp for what that does and does not reproduce.
#
#   ruby benchmarks/latency.rb
#   DELAY_MS=5,25,50 REQUESTS=200 CONCURRENCY=20 ruby benchmarks/latency.rb
#
# DELAY_MS is one-way, so the round trip is twice it. Every server runs through
# a relay, including at 0ms, so the relay is in the baseline rather than a
# handicap applied to one side.

ENV["RUNS"] ||= "1"
require_relative "compare"
require "impair"

DELAYS_MS = ENV.fetch("DELAY_MS", "0,25").split(",").map { |value| Float(value) }
LOSS = Integer(ENV.fetch("LOSS", "0"))
REPEATS = Integer(ENV.fetch("REPEATS", "3"))
SEED = Integer(ENV.fetch("SEED", "1234"))

def median_of(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end

def with_udp_relay(target_port, delay_ms)
  proxy = Impair::Udp.new(
    host: "::1", target_host: "::1", target_port: target_port,
    delay: delay_ms / 1000.0, loss: LOSS, seed: SEED
  ).start
  yield proxy.port
ensure
  proxy&.stop
end

# The TCP stall per lost segment is one round trip, and Impair derives that as
# 2 * delay (Impair::Config#rtt) rather than taking it separately: two knobs
# for one quantity is how the two arms drift apart. This passed rtt: as well,
# which Config now rejects outright, so this benchmark raised ArgumentError on
# every run. Dropping it preserves the behaviour, since the value passed was
# exactly 2 * delay.
def with_tcp_relay(target_port, delay_ms, host: "127.0.0.1")
  proxy = Impair::Tcp.new(
    host: host, target_host: host, target_port: target_port,
    delay: delay_ms / 1000.0, loss: LOSS, seed: SEED
  ).start
  yield proxy.port
ensure
  proxy&.stop
end

def measure_with_delay(name, delay_ms)
  port = free_port
  case name
  when "quicsilver"
    with_quicsilver(port) do
      with_udp_relay(port, delay_ms) { |front| measure_quicsilver(front) }
    end
  when "falcon"
    with_falcon(port) do
      with_tcp_relay(port, delay_ms) { |front| measure_async("falcon", "HTTP/2", front) }
    end
  when "puma"
    with_puma(port) do
      with_tcp_relay(port, delay_ms) { |front| measure_async("puma", "HTTP/1.1", front, host: "127.0.0.1") }
    end
  end
end

puts "Quicsilver, Falcon and Puma over a delayed link"
puts "#{REQUESTS} requests, #{CONCURRENCY} in flight, #{REPEATS} repeats, all over TLS"
puts "delay is one-way in milliseconds, so the round trip is twice it"
puts "every server runs through an impairment relay, including at 0ms"
puts "loss 1-in-#{LOSS} packets, costing the affected stream one round trip" if LOSS.positive?
puts

rows = []

DELAYS_MS.each do |delay_ms|
  %w[quicsilver falcon puma].each do |name|
    attempts = REPEATS.times.filter_map do
      result = measure_with_delay(name, delay_ms)
      next unless result

      stats = Benchmarks.stats(result.times)
      {rps: result.rps, p50: stats[:p50], p95: stats[:p95], p99: stats[:p99], failed: result.failed}
    rescue StandardError => error
      warn "#{name} at #{delay_ms}ms failed: #{error.class}: #{error.message}"
      warn error.backtrace.first(3).join("\n") if ENV["DEBUG"]
      nil
    end
    next if attempts.empty?

    rows << [delay_ms, name, attempts]
  end
end

protocols = {"quicsilver" => "HTTP/3", "falcon" => "HTTP/2", "puma" => "HTTP/1.1"}

puts format("%-8s %-12s %-9s %9s %9s %9s %9s %8s",
  "delay", "server", "protocol", "Req/s", "p50", "p95", "p99", "Failed")
puts "-" * 84
rows.each do |(delay_ms, name, attempts)|
  puts format("%6.0fms %-12s %-9s %9.0f %7.2fms %7.2fms %7.2fms %8d",
    delay_ms, name, protocols.fetch(name),
    median_of(attempts.map { |a| a[:rps] }),
    median_of(attempts.map { |a| a[:p50] }),
    median_of(attempts.map { |a| a[:p95] }),
    median_of(attempts.map { |a| a[:p99] }),
    attempts.sum { |a| a[:failed] })
end

puts
puts "HTTP/1.1 opens a connection per concurrent request, so it pays the"
puts "handshake more often as delay rises. HTTP/2 and HTTP/3 multiplex over one."
