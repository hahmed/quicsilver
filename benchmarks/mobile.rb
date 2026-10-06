#!/usr/bin/env ruby
# frozen_string_literal: true

# A phone's network, for a few seconds at a time.
#
# The link's RTT swings, loss comes in bursts, and every couple of seconds
# the NAT forgets the client's mapping. QUIC was built for the last one:
# the client's source port changes, the server validates the new path, and
# the connection carries on (RFC 9000 §9). A TCP connection is identified by
# that port, so when it changes the connection is gone and every stream on
# it dies with it; the client starts over with a new handshake.
#
#   client ──▶ Impair::Udp (rebind every 2s)  ──▶ Quicsilver  HTTP/3
#   client ──▶ Impair::Tcp (reset every 2s)   ──▶ Falcon      HTTP/2
#   client ──▶ Impair::Tcp (reset every 2s)   ──▶ Puma        HTTP/1.1
#
# rebind and reset are the same event seen by the two transports, which is
# why the schedule is one Scenario driving all three arms. RTT and loss ride
# along so the rebind lands on a busy link rather than a quiet one.
#
#   ruby benchmarks/mobile.rb
#   REBIND_EVERY=1 REQUESTS=2000 ruby benchmarks/mobile.rb
#
# Failed counts requests that got no 200, which for TCP includes every
# request in flight when the reset landed. That is the finding, not noise.

ENV["RUNS"] ||= "1"
ENV["QUIC_ADDRESS"] ||= "127.0.0.1"
require_relative "compare"
require "impair"

HOST = "127.0.0.1"
SERVERS = ENV.fetch("SERVERS", "quicsilver,falcon,puma").split(",")
REBIND_EVERY = Float(ENV.fetch("REBIND_EVERY", "2"))
DELAY_MS = Float(ENV.fetch("DELAY_MS", "20"))
LOSS = Integer(ENV.fetch("LOSS", "50"))
BURST = Integer(ENV.fetch("BURST", "5"))
REPEATS = Integer(ENV.fetch("REPEATS", "3"))
SEED = Integer(ENV.fetch("SEED", "1234"))
PROTOCOLS = {"quicsilver" => "HTTP/3", "falcon" => "HTTP/2", "puma" => "HTTP/1.1"}.freeze

# The one schedule. The RTT swings ±10ms around the base on a 6s period;
# the NAT rebinds on the interval. A TCP relay has no rebind, so it resets:
# that is what a rebind does to TCP.
SCENARIO = Impair::Scenario.new do
  every(0.1) { |relay, t| relay.update(delay: DELAY_MS / 1000.0 + wave(t, amplitude: 0.010, period: 6)) }
  every(REBIND_EVERY) do |relay, t|
    next if t.zero? # the first tick is t=0; nothing to rebind yet

    relay.respond_to?(:rebind) ? relay.rebind : relay.reset
  end
end

def link
  {loss: LOSS, burst: BURST, delay: DELAY_MS / 1000.0, seed: SEED}
end

def with_impaired(name)
  relay_class = (name == "quicsilver") ? Impair::Udp : Impair::Tcp
  port = free_port
  server = case name
  when "quicsilver" then method(:with_quicsilver)
  when "falcon" then method(:with_falcon)
  when "puma" then method(:with_puma)
  end
  server.call(port) do
    relay = relay_class.new(host: HOST, target_host: HOST, target_port: port, **link).start
    relay.run(SCENARIO)
    begin
      result = yield relay.port
      [result, relay.stop]
    ensure
      relay.stop
    end
  end
end

def median_of(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end

puts "A mobile link: RTT swinging, bursty loss, NAT rebinding every #{REBIND_EVERY}s"
puts "#{REQUESTS} requests, #{CONCURRENCY} in flight, #{REPEATS} repeats"
puts "connections: " + CONNECTIONS.map { |proto, n| "#{proto} on #{n}" }.join(", ")
puts format("base RTT %dms ±20ms, loss 1-in-%d in bursts of ~%d, seed %d", DELAY_MS * 2, LOSS, BURST, SEED)
puts "QUIC rebinds; TCP has no such thing, so it is reset on the same schedule"
puts "client retries: #{RETRIES}"
puts

rows = SERVERS.filter_map do |name|
  attempts = REPEATS.times.filter_map do
    result, counts = with_impaired(name) do |port|
      (name == "quicsilver") ? measure_quicsilver(port) : measure_async(name, PROTOCOLS[name], port, host: HOST)
    end
    stats = Benchmarks.stats(result.times)
    {rps: result.rps, p50: stats[:p50], p95: stats[:p95], p99: stats[:p99], failed: result.failed,
     completed: result.times.size, events: counts.scenario_events, measured: counts.loss_rate}
  rescue StandardError => error
    warn "#{name} failed: #{error.class}: #{error.message}"
    warn error.backtrace.first(3).join("\n") if ENV["DEBUG"]
    nil
  end
  next if attempts.empty?

  [name, attempts]
end

puts format("%-10s %-8s %8s %7s %9s %9s %9s %9s %7s", "server", "protocol", "measured", "Req/s", "p50", "p95", "p99", "completed", "Failed")
puts "-" * 86
rows.each do |(name, attempts)|
  puts format("%-10s %-8s %7.2f%% %7.0f %7.2fms %7.2fms %7.2fms %9d %7d",
    name, PROTOCOLS[name],
    median_of(attempts.map { |a| a[:measured] }) * 100,
    median_of(attempts.map { |a| a[:rps] }),
    median_of(attempts.map { |a| a[:p50] }),
    median_of(attempts.map { |a| a[:p95] }),
    median_of(attempts.map { |a| a[:p99] }),
    attempts.sum { |a| a[:completed] },
    attempts.sum { |a| a[:failed] })
end
puts
puts "Failed is requests that got no 200, with RETRIES=#{RETRIES}. At 0 that is every"
puts "TCP request in flight when the reset landed; a browser would retry them,"
puts "so RETRIES=3 shows the user's view and 0 shows the transport's."
