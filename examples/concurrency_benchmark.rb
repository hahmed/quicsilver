#!/usr/bin/env ruby

# Benchmark quicsilver throughput at different concurrency levels.
# Comparable to Falcon vs Puma benchmarks (4 workers, varying connections).
#
#   bundle exec rackup -s quicsilver -p 4433  (in another terminal)
#   bundle exec ruby examples/concurrency_benchmark.rb

require "bundler/setup"
require "quicsilver"

HOST = "localhost"
PORT = 4433
DURATION = 5  # seconds per test
WARMUP_REQUESTS = 20

def benchmark(concurrency, duration)
  stop = false
  completed = 0
  errors = 0
  mutex = Mutex.new

  threads = concurrency.times.map do
    Thread.new do
      client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
      until stop
        begin
          response = client.get("/h3/ping")
          mutex.synchronize do
            if response[:status] == 200
              completed += 1
            else
              errors += 1
            end
          end
        rescue => e
          mutex.synchronize { errors += 1 }
        end
      end
      client.disconnect
    end
  end

  sleep duration
  stop = true
  threads.each { |t| t.join(5) }

  [completed, errors]
end

puts "🔨 Quicsilver Concurrency Benchmark"
puts "   Target: https://#{HOST}:#{PORT}"
puts "   Duration: #{DURATION}s per level"
puts "=" * 60

# Warmup
print "   Warming up..."
client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
WARMUP_REQUESTS.times { client.get("/h3/ping") }
client.disconnect
puts " done"

results = []

[1, 4, 10, 20, 40, 80].each do |concurrency|
  print "   #{concurrency} connections... "
  completed, errors = benchmark(concurrency, DURATION)
  rps = (completed.to_f / DURATION).round(0)
  results << [concurrency, rps, errors]
  puts "#{rps} req/s (#{errors} errors)"
end

puts "\n" + "=" * 60
puts "📊 Results"
puts "-" * 60
puts "  #{"Connections".ljust(15)} #{"Req/s".rjust(10)} #{"Errors".rjust(10)}"
puts "-" * 60
results.each do |conns, rps, errors|
  bar = "█" * [rps / 100, 40].min
  puts "  #{conns.to_s.ljust(15)} #{rps.to_s.rjust(10)} #{errors.to_s.rjust(10)}  #{bar}"
end

if results.size >= 2
  base = results.first[1]
  peak = results.max_by { |_, rps, _| rps }
  puts "\n  Peak: #{peak[1]} req/s at #{peak[0]} connections"
  puts "  Scale: #{(peak[1].to_f / base).round(1)}x from #{results.first[0]} to #{peak[0]} connections"
end

puts "\n✅ Done"
