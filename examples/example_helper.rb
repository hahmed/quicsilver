# frozen_string_literal: true

# Shared helper for examples — uses the `localhost` gem to generate
# self-signed TLS certificates so examples work without manual setup.
#
# Usage:
#   require_relative "example_helper"
#   server = Quicsilver::Server.new(4433, app: app, server_configuration: EXAMPLE_TLS_CONFIG)

require "bundler/setup"
require "json"
require "socket"
require "thread"
require "quicsilver"
require "localhost/authority"

authority = Localhost::Authority.fetch
EXAMPLE_TLS_CONFIG = Quicsilver::Transport::Configuration.new(
  authority.certificate_path,
  authority.key_path
)

module Example
  module_function

  def wait_until(timeout: 5, interval: 0.01)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep interval
    end
  end

  def available_udp_port(host = "127.0.0.1")
    socket = UDPSocket.new
    socket.bind(host, 0)
    socket.addr[1]
  ensure
    socket&.close
  end

  def json_response(status, body)
    [status, { "content-type" => "application/json" }, [JSON.generate(body) << "\n"]]
  end

  def text_response(status, body)
    [status, { "content-type" => "text/plain" }, [body]]
  end

  def say(line = "")
    puts line
  end

  def heading(text, level: 2)
    say unless heading_count.zero?
    say "#{'#' * level} #{text}"
    @heading_count += 1
  end

  def detail(label, value, width: 22)
    say format("  %-#{width}s %s", label, value)
  end


  def heading_count
    @heading_count ||= 0
  end
end
