# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../http3_test_helper"

# Tests 0-RTT early data policy enforcement at the server level (RFC 8470).
# The server decides whether to reject unsafe methods on 0-RTT or pass them
# through to the Rack app with env["quicsilver.early_data"] set.
class EarlyDataValidationTest < Minitest::Test
  parallelize_me!
  include HTTP3TestHelpers

  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
  UNSAFE_METHODS = %w[POST PUT DELETE PATCH].freeze

  # --- :reject policy (default) ---

  UNSAFE_METHODS.each do |method|
    define_method("test_reject_policy_sends_425_for_#{method.downcase}_on_early_data") do
      error_status = nil
      server, connection, stream = setup_request(method, policy: :reject)

      connection.stub(:send_error, ->(s, status, msg) { error_status = status }) do
        server.instance_variable_get(:@request_handler).call(connection, stream, early_data: true)
      end

      assert_equal 425, error_status
    end
  end

  SAFE_METHODS.each do |method|
    define_method("test_reject_policy_allows_#{method.downcase}_on_early_data") do
      app_called = false
      server, connection, stream = setup_request(method, policy: :reject,
        app: ->(env) { app_called = true; [200, {}, ["OK"]] })

      connection.stub(:send_response, ->(*args) {}) do
        server.instance_variable_get(:@request_handler).call(connection, stream, early_data: true)
      end

      assert app_called, "#{method} should pass through to app on early data in :reject mode"
    end
  end

  UNSAFE_METHODS.each do |method|
    define_method("test_reject_policy_allows_#{method.downcase}_on_normal_data") do
      app_called = false
      server, connection, stream = setup_request(method, policy: :reject,
        app: ->(env) { app_called = true; [200, {}, ["OK"]] })

      connection.stub(:send_response, ->(*args) {}) do
        server.instance_variable_get(:@request_handler).call(connection, stream, early_data: false)
      end

      assert app_called, "#{method} should pass through on non-early data"
    end
  end

  # --- :allow policy ---

  UNSAFE_METHODS.each do |method|
    define_method("test_allow_policy_passes_#{method.downcase}_on_early_data") do
      received_env = nil
      server, connection, stream = setup_request(method, policy: :allow,
        app: ->(env) { received_env = env; [200, {}, ["OK"]] })

      connection.stub(:send_response, ->(*args) {}) do
        server.instance_variable_get(:@request_handler).call(connection, stream, early_data: true)
      end

      assert received_env, "#{method} should reach app in :allow mode"
      assert_equal true, received_env["quicsilver.early_data"]
    end
  end

  def test_allow_policy_app_can_return_425
    response_status = nil
    server, connection, stream = setup_request("POST", policy: :allow,
      app: ->(env) {
        env["quicsilver.early_data"] ? [425, {}, ["Too Early"]] : [200, {}, ["OK"]]
      })

    connection.stub(:send_response, ->(s, status, h, b, **_kw) { response_status = status }) do
      server.instance_variable_get(:@request_handler).call(connection, stream, early_data: true)
    end

    assert_equal 425, response_status
  end

  # --- env["quicsilver.early_data"] is always set ---

  def test_env_early_data_true_on_early_data
    received_env = nil
    server, connection, stream = setup_request("GET", policy: :reject,
      app: ->(env) { received_env = env; [200, {}, ["OK"]] })

    connection.stub(:send_response, ->(*args) {}) do
      server.instance_variable_get(:@request_handler).call(connection, stream, early_data: true)
    end

    assert_equal true, received_env["quicsilver.early_data"]
  end

  def test_env_early_data_false_on_normal_data
    received_env = nil
    server, connection, stream = setup_request("GET", policy: :reject,
      app: ->(env) { received_env = env; [200, {}, ["OK"]] })

    connection.stub(:send_response, ->(*args) {}) do
      server.instance_variable_get(:@request_handler).call(connection, stream, early_data: false)
    end

    assert_equal false, received_env["quicsilver.early_data"]
  end

  private

  def setup_request(method, policy:, app: nil)
    app ||= ->(env) { [200, {}, ["OK"]] }
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path, early_data_policy: policy)
    server = Quicsilver::Server.new(4433, app: app, server_configuration: config)

    data = build_request(":method" => method, ":scheme" => "https",
                         ":authority" => "localhost", ":path" => "/")
    stream = Quicsilver::Transport::InboundStream.new(4)
    stream.stream_handle = 0xBEEF
    stream.append_data(data)

    connection = Quicsilver::Transport::Connection.new(12345, [12345, 67890])
    server.connections[12345] = connection

    [server, connection, stream]
  end
end
