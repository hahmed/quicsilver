# frozen_string_literal: true

require "test_helper"
require_relative "../lib/quicsilver/server"
require_relative "../lib/quicsilver/server_configuration"

class ServerTest < Minitest::Test
  def test_initialize_with_defaults
    server = create_server

    assert_equal 4433, server.port
    assert_equal "0.0.0.0", server.address
    assert_instance_of Quicsilver::ServerConfiguration, server.server_configuration
    refute server.running?
  end

  def test_initialize_with_custom_port_and_address
    server = create_server(8080, address: "127.0.0.1")

    assert_equal 8080, server.port
    assert_equal "127.0.0.1", server.address
  end

  def test_initialize_with_custom_server_configuration_raises_when_cert_missing
    assert_raises(Quicsilver::ServerConfigurationError) do
      Quicsilver::ServerConfiguration.new("certificates/missing.pem", "certificates/key.pem")
    end
  end

  def test_initialize_with_custom_server_configuration_raises_when_key_missing
    assert_raises(Quicsilver::ServerConfigurationError) do
      Quicsilver::ServerConfiguration.new("certificates/server.crt", "certificates/missing_key.pem")
    end
  end

  def test_initialize_with_custom_rack_app
    app = ->(env) { [200, {}, ["custom"]] }
    server = Quicsilver::Server.new(4433, app: app)

    assert_instance_of Quicsilver::Server, server
  end

  def test_server_info_returns_hash_with_details
    server = create_server
    info = server.server_info

    assert_instance_of Hash, info
    assert_equal "0.0.0.0", info[:address]
    assert_equal 4433, info[:port]
    assert_equal false, info[:running]
    assert info.key?(:cert_file)
    assert info.key?(:key_file)
  end

  def test_stop_when_not_running
    server = create_server

    assert_nil server.stop
    refute server.running?
  end

  def test_handle_stream_with_receive_event
    stream_id = 1
    event = Quicsilver::Server::STREAM_EVENT_RECEIVE
    data = "test data"
    connection_data = [12345, 67890]  # Mock connection_data

    Quicsilver::Server.stream_buffers.clear
    Quicsilver::Server.handle_stream(connection_data, stream_id, event, data)

    assert_equal "test data", Quicsilver::Server.stream_buffers[stream_id]
  end

  def test_handle_stream_accumulates_data
    stream_id = 2
    event = Quicsilver::Server::STREAM_EVENT_RECEIVE
    connection_data = [12345, 67890]  # Mock connection_data

    Quicsilver::Server.stream_buffers.clear
    Quicsilver::Server.handle_stream(connection_data, stream_id, event, "chunk1")
    Quicsilver::Server.handle_stream(connection_data, stream_id, event, "chunk2")
    Quicsilver::Server.handle_stream(connection_data, stream_id, event, "chunk3")

    assert_equal "chunk1chunk2chunk3", Quicsilver::Server.stream_buffers[stream_id]
  end

  private

  def create_server(port=4433, options={})
    defaults = {
      cert_file: "certificates/server.crt",
      key_file: "certificates/server.key"
    }

    normalized_cert_file = options.delete(:cert_file) || defaults[:cert_file]
    normalized_key_file = options.delete(:key_file) || defaults[:key_file]

    server_config = options.delete(:server_configuration) || Quicsilver::ServerConfiguration.new(normalized_cert_file, normalized_key_file)
    Quicsilver::Server.new(port, server_configuration: server_config, **options)
  end
end
