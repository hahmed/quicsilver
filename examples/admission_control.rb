#!/usr/bin/env ruby
# frozen_string_literal: true

# Graduated admission control.
#
#   bundle exec ruby examples/admission_control.rb
#
# Shows why queue depth alone is not enough to decide whether to shed, and what
# the QUIC-native signals add on top.
#
# Three scenarios run against the same server:
#
#   1. BURST      short spike, fast handler   -> queue absorbs it, nothing shed
#   2. SATURATION sustained load, slow handler -> waits blow the budget, shed
#   3. STREAM CAP tiny stream limit            -> peers block on the wire and
#                                                 PEER_NEEDS_STREAMS fires
#
# Scenario 1 and 2 reach the same queue depth. Only wait time tells them apart,
# which is the whole argument for measuring it.
#
# Env:
#   WAIT_LIMIT_MS   admission wait budget (default 250)
#   THREADS         worker threads (default 2)
#   QUEUE           max queue size (default 32)

# Deliberately not using example_helper: this script should stay runnable
# without a working bundle so it can be pointed at any checkout.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "quicsilver"
require "localhost/authority"
require "socket"

$stdout.sync = true

# Shedding is expected here and logs a warning per refused request. Set
# VERBOSE=1 to see them.
Quicsilver.logger = Logger.new(ENV["VERBOSE"] ? $stderr : File::NULL)

THREADS       = Integer(ENV.fetch("THREADS", "2"))
QUEUE         = Integer(ENV.fetch("QUEUE", "32"))
WAIT_LIMIT_MS = Integer(ENV.fetch("WAIT_LIMIT_MS", "250"))
HOST          = "127.0.0.1"

# --- app ---------------------------------------------------------------------

$handler_delay = 0.0

APP = lambda do |_env|
  sleep $handler_delay if $handler_delay > 0
  [200, {"content-type" => "text/plain"}, ["OK"]]
end

# --- reporting ---------------------------------------------------------------

def banner(title)
  puts
  puts "=" * 78
  puts title
  puts "=" * 78
end

def report(server, label)
  stats = server.stats
  scheduler = stats["scheduler"]
  admission = stats["admission"]
  wait = admission["wait"]

  puts format(
    "  %-14s depth=%-3s wait_p50=%-8s wait_p99=%-8s pressure=%-6s shed=%s",
    label,
    "#{scheduler["pending"]}/#{scheduler["max_queue_size"]}",
    "#{wait["p50_ms"]}ms",
    "#{wait["p99_ms"]}ms",
    admission["pressure"],
    admission["shed_count"]
  )
end

def verdict(text)
  puts
  puts "  -> #{text}"
end

# --- driver ------------------------------------------------------------------

# Fires `count` concurrent requests and classifies the outcomes.
# shared: true drives every request over one QUIC connection, so concurrency
# competes for that connection's stream credit. With a client each, every
# connection only ever has one stream open and no limit is ever reached.
def drive(port, count:, concurrency:, shared: false)
  results = Queue.new
  work = Queue.new
  count.times { |i| work << i }
  concurrency.times { work << :stop }

  shared_client = shared ? Quicsilver::Client.new(HOST, port, unsecure: true) : nil

  threads = concurrency.times.map do
    Thread.new do
      client = shared_client || Quicsilver::Client.new(HOST, port, unsecure: true)
      begin
        while (item = work.pop) != :stop
          begin
            response = client.get("/render/#{item}", timeout: 10)
            results << response.status
          rescue Quicsilver::TimeoutError
            results << :timeout
          rescue => e
            results << e.class.name
          end
        end
      ensure
        client.disconnect rescue nil unless shared
      end
    end
  end
  threads.each(&:join)
  shared_client&.disconnect rescue nil

  outcomes = Hash.new(0)
  outcomes[results.pop] += 1 until results.empty?
  outcomes
end

def summarise(outcomes)
  ok = outcomes[200]
  shed = outcomes[503]
  other = outcomes.reject { |k, _| k == 200 || k == 503 }
  line = "  served=#{ok} shed=#{shed}"
  line += " other=#{other.inspect}" unless other.empty?
  puts line
end

# --- setup -------------------------------------------------------------------

def available_udp_port(host)
  socket = UDPSocket.new
  socket.bind(host, 0)
  socket.addr[1]
ensure
  socket&.close
end

def wait_until(timeout: 5, interval: 0.01)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    raise "timed out waiting for server" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep interval
  end
end

authority = Localhost::Authority.fetch
tls = Quicsilver::Transport::Configuration.new(
  authority.certificate_path,
  authority.key_path
)

port = available_udp_port(HOST)
server = Quicsilver::Server.new(
  port,
  app: APP,
  server_configuration: tls,
  threads: THREADS,
  max_queue_size: QUEUE,
  wait_limit: WAIT_LIMIT_MS / 1000.0
)

blocked_peers = []
server.on_peer_needs_streams do |_connection, bidirectional|
  blocked_peers << bidirectional
end

server_thread = Thread.new { server.start }
wait_until { server.running? }

puts "quicsilver admission control demo"
puts "  threads=#{THREADS} queue=#{QUEUE} wait_limit=#{WAIT_LIMIT_MS}ms port=#{port}"

begin
  # === 1. burst ===============================================================

  banner("1. BURST - short spike, fast handler")
  puts "  Queue fills, but work drains faster than the budget. Nothing is shed:"
  puts "  refusing here would throw away work that was going to succeed."
  puts

  $handler_delay = 0.0
  report(server, "before")
  outcomes = drive(port, count: 60, concurrency: 12)
  report(server, "after")
  summarise(outcomes)

  burst_wait = server.stats.dig("admission", "wait", "p99_ms")
  burst_shed = server.stats.dig("admission", "shed_count")
  verdict("p99 wait #{burst_wait}ms, under the #{WAIT_LIMIT_MS}ms budget -> absorbed")

  # === 2. saturation ==========================================================

  banner("2. SATURATION - sustained load, slow handler")
  puts "  Same queue, same depth. Now each request takes long enough that the"
  puts "  queue cannot drain within the budget, so waits climb and we refuse"
  puts "  deliberately rather than serving responses nobody is waiting for."
  puts

  server.admission.wait_time.reset
  $handler_delay = 0.4
  report(server, "before")
  outcomes = drive(port, count: 60, concurrency: 12)
  report(server, "after")
  summarise(outcomes)

  sat_wait = server.stats.dig("admission", "wait", "p99_ms")
  sat_shed = server.stats.dig("admission", "shed_count") - burst_shed
  verdict("p99 wait #{sat_wait}ms, over the #{WAIT_LIMIT_MS}ms budget -> #{sat_shed} shed")

  # === comparison =============================================================

  banner("WHY DEPTH IS NOT ENOUGH")
  puts format("  burst      p99 wait %-9s shed %s", "#{burst_wait}ms", burst_shed)
  puts format("  saturation p99 wait %-9s shed %s", "#{sat_wait}ms", sat_shed)
  puts
  puts "  Both reached similar queue depth. Depth alone cannot separate them;"
  puts "  wait time can. That is why admission is driven by wait time here and"
  puts "  depth is only the backstop."

  # === 3. stream cap ==========================================================

  banner("3. STREAM CAP - backpressure on the wire, before the queue")
  puts "  A second server advertising room for only 2 concurrent streams. Ten"
  puts "  requests share one connection, so eight of them wait in QUIC flow"
  puts "  control rather than in our queue, and nothing is refused."
  puts
  puts "  Note this limit is set at handshake, not adjusted later: MAX_STREAMS"
  puts "  is monotonic (RFC 9000), so credit already granted cannot be revoked."
  puts "  grant_streams can widen a live connection, never narrow it."
  puts

  capped_port = available_udp_port(HOST)
  capped_config = Quicsilver::Transport::Configuration.new(
    authority.certificate_path,
    authority.key_path,
    max_concurrent_requests: 2
  )
  capped = Quicsilver::Server.new(
    capped_port,
    app: ->(_env) { sleep 0.05; [200, {"content-type" => "text/plain"}, ["OK"]] },
    server_configuration: capped_config,
    threads: THREADS,
    max_queue_size: QUEUE
  )

  widened = 0
  capped.on_peer_needs_streams do |connection, _bidirectional|
    # Demand we are not serving. Widening is allowed; narrowing is not.
    if capped.admission.pressure < 0.5
      capped.grant_streams(connection, 8)
      widened += 1
    end
  end

  capped_thread = Thread.new { capped.start }
  wait_until { capped.running? }

  begin
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcomes = drive(capped_port, count: 30, concurrency: 10, shared: true)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    summarise(outcomes)

    stats = capped.stats["admission"]
    puts
    puts "  elapsed:                  #{(elapsed * 1000).round}ms"
    puts "  peer_needs_streams fired: #{stats["peer_needs_streams"]}"
    puts "  windows widened:          #{widened}"
    puts "  shed:                     #{stats["shed_count"]}"

    if stats["peer_needs_streams"].to_i > 0
      verdict("peers blocked on our advertised limit - demand was visible " \
              "before it reached the queue, and nothing had to be refused")
    else
      verdict("no peer blocked this run; credit was extended as fast as " \
              "streams completed")
    end
  ensure
    capped.stop rescue nil
    capped_thread&.join(2)
  end

  banner("SUMMARY")
  puts "  layer 1  queue          absorb bursts, add no latency, waste nothing"
  puts "  layer 2  stream window  slow peers on the wire before refusing"
  puts "  layer 3  shed 503       deliberate refusal once waits exceed budget"
  puts
  puts "  Final stats:"
  puts "    #{server.stats["admission"].reject { |k, _| k == "wait" }.inspect}"
  puts "    wait: #{server.stats.dig("admission", "wait").inspect}"
  puts
ensure
  server.stop rescue nil
  server_thread&.join(2)
end
