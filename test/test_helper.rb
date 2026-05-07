$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "quicsilver"
require "localhost/authority"
require "socket"

require "minitest/autorun"
require "minitest/focus"

# Silence server logs during tests. Override per test with:
#   Quicsilver.logger = Logger.new($stderr)
Quicsilver.logger = Logger.new(File::NULL)

def cert_file_path
  Localhost::Authority.fetch.certificate_path
end

def key_file_path
  Localhost::Authority.fetch.key_path
end

# Find an available port by binding to port 0 (OS assigns a free one).
# Uses UDP since QUIC is UDP-based — ensures the port is actually free.
# Keeps the socket open until the port is recorded to prevent races.
PORT_MUTEX = Mutex.new
ALLOCATED_PORTS = Set.new

def find_available_port
  PORT_MUTEX.synchronize do
    10.times do
      socket = UDPSocket.new
      socket.bind("127.0.0.1", 0)
      port = socket.addr[1]
      socket.close
      unless ALLOCATED_PORTS.include?(port)
        ALLOCATED_PORTS << port
        return port
      end
    end
    raise "Could not find an available port after 10 attempts"
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