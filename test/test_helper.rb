$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "quicsilver"
require "localhost/authority"
require "socket"

require "minitest/autorun"
require "minitest/focus"

# Silence server logs during tests. Override per test with:
#   Quicsilver.logger = Logger.new($stderr)
Quicsilver.logger = Logger.new(File::NULL)
# protocol-rack logs app exceptions via the console gem, which Quicsilver.logger does not cover.
ENV["CONSOLE_LEVEL"] ||= "fatal"

def cert_file_path
  Localhost::Authority.fetch.certificate_path
end

def key_file_path
  Localhost::Authority.fetch.key_path
end

# Find an available UDP port for a Quicsilver server.
#
# Quicsilver servers bind to 0.0.0.0 by default, so probe the same wildcard
# address. Binding only 127.0.0.1 can report a port as free even when a wildcard
# server bind would still fail on another local interface.
PORT_MUTEX = Mutex.new
ALLOCATED_PORTS = Set.new

# Below the ephemeral range on both Linux (32768) and macOS (49152), so the
# kernel never hands one of these out on its own. Probing for an ephemeral port
# and then closing it loses a race the suite actually hit: a client socket
# binding port 0 got the port back before the server bound it, and setup died
# with "Address already in use". Picking outside the range means only another
# deliberate bind can collide.
PORT_RANGE = (20_000...32_000)
# Offset per process so the two test_parallel processes do not walk in step.
PORT_CURSOR = [ PORT_RANGE.first + (Process.pid % (PORT_RANGE.size - 200)) ]

def find_available_port
  PORT_MUTEX.synchronize do
    200.times do
      port = PORT_CURSOR[0]
      PORT_CURSOR[0] += 1
      PORT_CURSOR[0] = PORT_RANGE.first if PORT_CURSOR[0] >= PORT_RANGE.last
      next if ALLOCATED_PORTS.include?(port)

      # Probe dual-stack. The server's listener binds both families, so a
      # port held only on IPv6 (a local Postgres on [::1]:65000, say) must
      # read as taken; an IPv4-only probe reports it free.
      begin
        socket = UDPSocket.new(Socket::AF_INET6)
        socket.setsockopt(:IPV6, :V6ONLY, 0)
        socket.bind("::", port)
      rescue Errno::EADDRINUSE, Errno::EACCES
        next
      ensure
        socket&.close
      end

      ALLOCATED_PORTS << port
      return port
    end
    raise "Could not find an available port after 200 attempts"
  end
end

# Wait for server to be ready instead of sleeping a fixed duration.
# Polls server.running? with a short sleep, typically returns in <50ms.
def wait_for_server(server, timeout: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until server.running?
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      raise "Server failed to start within #{timeout}s"
    end
    sleep 0.01
  end
end