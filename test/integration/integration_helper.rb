# frozen_string_literal: true

require "test_helper"
require "open3"

module IntegrationHelpers
  # Use brew's curl which has HTTP/3 support via ngtcp2/nghttp3
  CURL_BIN = if File.executable?("/opt/homebrew/opt/curl/bin/curl")
    "/opt/homebrew/opt/curl/bin/curl"
  elsif File.executable?("/usr/local/opt/curl/bin/curl")
    "/usr/local/opt/curl/bin/curl"
  else
    "curl"
  end

  def start_server(app)
    @port = find_available_port
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    @server = Quicsilver::Server.new(@port, app: app, server_configuration: config)
    @server_thread = Thread.new { @server.start }
    wait_for_server(@server)
  end

  def stop_server
    @server&.stop rescue nil
    @server_thread&.join(3)
  end

  def curl(*args)
    cmd_args = [CURL_BIN, "--http3-only", "-k", "-s", "--max-time", "5"] + args
    stdout, stderr, status = Open3.capture3(*cmd_args)
    CurlResult.new(stdout, stderr, status)
  end

  def curl_url(path = "/")
    "https://localhost:#{@port}#{path}"
  end

  def curl_http3_available?
    # CI's curl has no HTTP/3, so these 22 tests skip there and run locally.
    # That changes the timing of the whole suite, and races have only shown up
    # in the skipped configuration. Set FORCE_NO_CURL_HTTP3=1 to reproduce it
    # without a container.
    # Not a bare truthiness check: CI passes an empty string for the jobs that
    # should run these tests, and "" is truthy in Ruby.
    return false unless ENV["FORCE_NO_CURL_HTTP3"].to_s.empty?
    return @@curl_http3_available if defined?(@@curl_http3_available)
    # Check for nghttp3 linkage — much faster than `curl --version` (20ms vs 5s on macOS)
    if RUBY_PLATFORM =~ /darwin/
      output, = Open3.capture3("otool", "-L", CURL_BIN)
      @@curl_http3_available = output.include?("nghttp3")
    else
      output, = Open3.capture3(CURL_BIN, "--version")
      @@curl_http3_available = output.include?("HTTP3")
    end
  end

  CurlResult = Struct.new(:stdout, :stderr, :status) do
    def success?
      status.success?
    end

    def http_status
      stdout.match(/^HTTP\/3 (\d+)/m)&.captures&.first&.to_i
    end
  end
end
