$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "quicsilver"
require "localhost/authority"

require "minitest/autorun"
require "minitest/focus"

def cert_file_path
  Localhost::Authority.fetch.certificate_path
end

def key_file_path
  Localhost::Authority.fetch.key_path
end

# Wait for server to be ready instead of sleeping a fixed duration.
# Polls server.running? with a short sleep, typically returns in <50ms.
def wait_for_server(server, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until server.running?
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      raise "Server failed to start within #{timeout}s"
    end
    sleep 0.01
  end
end