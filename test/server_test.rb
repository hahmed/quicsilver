# frozen_string_literal: true

require "test_helper"
require_relative "../lib/quicsilver/server"
require_relative "../lib/quicsilver/server_configuration"

class ServerTest < Minitest::Test
  def test_initialize_with_defaults
    server = Quicsilver::Server.new

    assert_equal 4433, server.port
    assert_equal "0.0.0.0", server.address
    assert_instance_of Quicsilver::ServerConfiguration, server.server_configuration
    refute server.running?
  end

  def test_initialize_with_custom_port_and_address
    server = Quicsilver::Server.new(8080, address: "127.0.0.1")

    assert_equal 8080, server.port
    assert_equal "127.0.0.1", server.address
  end

  def test_initialize_with_custom_server_configuration
    config = Quicsilver::ServerConfiguration.new("custom.crt", "custom.key")
    server = Quicsilver::Server.new(4433, server_configuration: config)

    assert_equal config, server.server_configuration
    assert_equal "custom.crt", config.cert_file
    assert_equal "custom.key", config.key_file
  end

  def test_initialize_with_custom_rack_app
    app = ->(env) { [200, {}, ["custom"]] }
    server = Quicsilver::Server.new(4433, app: app)

    assert_instance_of Quicsilver::Server, server
  end

  def test_server_info_returns_hash_with_details
    server = Quicsilver::Server.new(4433)

    info = server.server_info

    assert_instance_of Hash, info
    assert_equal "0.0.0.0", info[:address]
    assert_equal 4433, info[:port]
    assert_equal false, info[:running]
    assert info.key?(:cert_file)
    assert info.key?(:key_file)
  end

  def test_stop_when_not_running
    server = Quicsilver::Server.new(4433)

    assert_nil server.stop
    refute server.running?
  end

  def test_rack_app_can_be_set
    app = ->(env) { [200, {}, ["test"]] }
    Quicsilver::Server.rack_app = app

    assert_equal app, Quicsilver::Server.rack_app
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
end
