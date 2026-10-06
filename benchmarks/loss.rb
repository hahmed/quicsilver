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
#   client ──▶ Impair::Udp (drops 1 in N)          ──▶ Quicsilver  HTTP/3
#   client ──▶ Impair::Tcp (stalls + halves cwnd 1 in N) ──▶ Falcon  HTTP/2
#   client ──▶ Impair::Tcp (stalls + halves cwnd 1 in N) ──▶ Puma    HTTP/1.1
#
# The three relays take the same link config. The TCP relay cannot drop bytes,
# so it charges what a drop costs instead: a one-RTT stall of the connection
# and a halved sender window for every segment the dice say was lost, an RTO
# and window collapse for a burst. Same loss probability per packet, same
# sender reaction; see Impair::Tcp for what that does and does not reproduce.
#
# Kernel shaping was tried first and abandoned. macOS dummynet does not shape
# the loopback interface: pings through a 3% pipe reported 0.0% loss, so the
# experiment was reporting "loss changes nothing" while dropping nothing. The
# relay counts what it drops, and a row is only reported when the relay
# confirms it saw every packet and the measured loss is close to the request.
#
#   ruby benchmarks/loss.rb
#   LOSS=0,50,20 DELAY_MS=15 BURST=5 REQUESTS=1500 ruby benchmarks/loss.rb
#   SERVERS=quicsilver,puma ruby benchmarks/loss.rb
#
# LOSS is 1-in-N, the way MsQuic's emulated-performance runs express it, with 0
# meaning no loss. 10 is a brutal 10%; real networks are 1-in-100 or worse.
#
# With REPLAY=1 the HTTP/3 arm records its loss decisions and the TCP arms
# replay them, so all three see the identical pattern rather than the same
# seed. Whatever difference remains is the protocol.

ENV["RUNS"] ||= "1"
# Every arm binds and dials one literal so the resolver order of "localhost"
# cannot pick a family the relay is not listening on. Puma only binds v4.
ENV["QUIC_ADDRESS"] ||= "127.0.0.1"
require_relative "compare"
require "impair"

HOST = "127.0.0.1"
SERVERS = ENV.fetch("SERVERS", "quicsilver,falcon,puma").split(",")
LOSS_RATES = ENV.fetch("LOSS", "0,100,50,20,10").split(",").map { |value| Integer(value) }
REORDER = Integer(ENV.fetch("REORDER", "0"))
# Mean length of a loss burst. Real links lose packets in runs, not
# independently, and i.i.d. loss understates HTTP/3: a burst confined to one
# stream's packets stalls that stream, where TCP would stall all of them. The
# overall rate stays 1-in-LOSS; only the clustering changes. 0 is i.i.d.
BURST = Integer(ENV.fetch("BURST", "0"))
# One-way delay in milliseconds, so RTT is twice this. Loss without a round
# trip understates itself: loopback retransmits in microseconds, and the cost
# of a retransmission is one RTT. This is the axis that makes loss hurt.
DELAY_MS = Float(ENV.fetch("DELAY_MS", "0"))
SEED = Integer(ENV.fetch("SEED", "1234"))
REPLAY = ENV["REPLAY"] == "1"
# Repeats per row, because this server's own throughput varies enough between
# runs to swallow the effect being measured. A single run once showed higher
# throughput at 9% loss than at none, which is not a finding about loss.
REPEATS = Integer(ENV.fetch("REPEATS", "3"))

PROTOCOLS = {"quicsilver" => "HTTP/3", "falcon" => "HTTP/2", "puma" => "HTTP/1.1"}.freeze

def link_for(loss)
  {
    loss: loss, reorder: REORDER, delay: DELAY_MS / 1000.0, seed: SEED,
    # burst is a clustering of loss, so it is meaningless without any, and
    # Impair rejects the pair rather than silently ignoring it.
    **(BURST.positive? && loss.positive? ? {burst: BURST} : {}),
  }
end

# Runs +name+ behind the matching relay and yields the relay's port. Returns
# [result, relay] with the relay stopped.
def with_impaired(name, loss, replay: nil)
  relay_class = (name == "quicsilver") ? Impair::Udp : Impair::Tcp
  port = free_port
  server = case name
  when "quicsilver" then method(:with_quicsilver)
  when "falcon" then method(:with_falcon)
  when "puma" then method(:with_puma)
  end

  server.call(port) do
    relay = relay_class.start(
      host: HOST, target_host: HOST, target_port: port,
      trace: REPLAY && replay.nil?, replay: replay, **link_for(loss)
    )
    begin
      result = case name
      when "quicsilver" then measure_quicsilver(relay.port)
      else measure_async(name, PROTOCOLS.fetch(name), relay.port, host: HOST)
      end
      [result, relay]
    ensure
      relay.stop
    end
  end
end

def median_of(values)
  sorted = values.sort
  sorted[sorted.length / 2]
end

puts "Head-of-line blocking under induced packet loss"
puts "#{REQUESTS} requests, #{CONCURRENCY} in flight, #{REPEATS} repeats, through a userspace impairment relay"
puts "connections: " + CONNECTIONS.map { |proto, n| "#{proto} on #{n}" }.join(", ")
puts "loss is 1-in-N applied in both directions, seed #{SEED}"
puts "bursts averaging #{BURST} packets, overall rate unchanged" if BURST.positive?
puts "one-way delay #{DELAY_MS}ms, so about #{(DELAY_MS * 2).round}ms round trip" if DELAY_MS.positive?
puts "TCP arms replay the HTTP/3 arm's loss decisions" if REPLAY
puts

rows = []

LOSS_RATES.each do |loss|
  SERVERS.each do |name|
    attempts = REPEATS.times.filter_map do |repeat|
      # With REPLAY, the HTTP/3 run of this row and repeat is the script.
      replay = REPLAY && name != "quicsilver" ? rows.dig(-1, :traces, repeat) : nil
      result, relay = with_impaired(name, loss, replay: replay)
      counts = relay.counts

      # Two things the relay must confirm before the row counts. That it saw
      # every packet -- kernel drops before the relay are invisible to
      # loss_rate -- and that the loss it applied is close to what was asked.
      # The relay cannot know how many packets the client sent, so the first
      # check is on its own queue only; the second catches the rest.
      if counts.overrun.positive?
        warn format("  %s 1-in-%d: relay overran its queue %d times, discarding", name, loss, counts.overrun)
        next
      end
      expected = loss.zero? ? 0.0 : 1.0 / loss
      if loss.positive? && counts.loss_rate < expected / 2
        warn format("  %s 1-in-%d: relay dropped only %.2f%%, discarding", name, loss, counts.loss_rate * 100)
        next
      end

      stats = Benchmarks.stats(result.times)
      {rps: result.rps, p50: stats[:p50], p95: stats[:p95], p99: stats[:p99],
       failed: result.failed, measured: counts.loss_rate,
       longest_burst: counts.longest_burst, trace: relay.trace}
    rescue StandardError => error
      warn "#{name} 1-in-#{loss} failed: #{error.class}: #{error.message}"
      warn error.backtrace.first(3).join("\n") if ENV["DEBUG"]
      nil
    end
    next if attempts.empty?

    rows << {loss: loss, name: name, attempts: attempts, traces: attempts.map { |a| a[:trace] }}
  end
end

puts format("%-9s %-10s %-8s %8s %5s %7s %9s %9s %9s %6s %13s",
  "loss", "server", "protocol", "measured", "burst", "Req/s", "p50", "p95", "p99", "Failed", "Req/s range")
puts "-" * 104
last_loss = nil
rows.each do |row|
  puts if last_loss && row[:loss] != last_loss
  last_loss = row[:loss]
  attempts = row[:attempts]
  rates = attempts.map { |a| a[:rps] }
  puts format("%-9s %-10s %-8s %7.2f%% %5d %7.0f %7.2fms %7.2fms %7.2fms %6d %13s",
    row[:loss].zero? ? "none" : "1-in-#{row[:loss]}",
    row[:name], PROTOCOLS.fetch(row[:name]),
    median_of(attempts.map { |a| a[:measured] }) * 100,
    attempts.map { |a| a[:longest_burst] }.max,
    median_of(rates),
    median_of(attempts.map { |a| a[:p50] }),
    median_of(attempts.map { |a| a[:p95] }),
    median_of(attempts.map { |a| a[:p99] }),
    attempts.sum { |a| a[:failed] },
    (rates.length > 1 ? format("%.0f-%.0f", rates.min, rates.max) : "single"))
end

puts
puts "The relay is in the path for every row, including the first, so the"
puts "no-loss row is the baseline rather than a direct connection."
puts "Loss is applied to both directions, so a request and its response each"
puts "face the dice. On TCP a lost segment stalls the whole connection one RTT"
puts "and halves the sender's window (RFC 5681); a burst waits out the RTO and"
puts "collapses it. No SACK, so the TCP rows are still conservative in TCP's favour."
