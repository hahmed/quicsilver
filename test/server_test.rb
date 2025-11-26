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

  # Skipped: These tests use mock connection_data that crashes the C extension
  # The C extension expects real MSQUIC connection pointers, not Ruby arrays
  # TODO: Either mock the C calls properly or test at integration level
  #
  # def test_handle_stream_with_receive_event
  #   server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
  #   stream_id = 1
  #   connection_handle = 12345
  #   connection_data = [connection_handle, 67890]
  #
  #   # First establish connection
  #   Quicsilver::Server.handle_stream(connection_data, 0, Quicsilver::Server::STREAM_EVENT_CONNECTION_ESTABLISHED, "")
  #
  #   # Now send data
  #   Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "test data")
  #
  #   connection = server.connections[connection_handle]
  #   assert_not_nil connection, "Connection should exist"
  #   stream = connection.get_stream(stream_id)
  #   assert_not_nil stream, "Stream should exist"
  #   assert_equal "test data", stream.buffer
  # end
  #
  # def test_handle_stream_accumulates_data
  #   server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
  #   stream_id = 2
  #   connection_handle = 12345
  #   connection_data = [connection_handle, 67890]
  #
  #   # First establish connection
  #   Quicsilver::Server.handle_stream(connection_data, 0, Quicsilver::Server::STREAM_EVENT_CONNECTION_ESTABLISHED, "")
  #
  #   # Send multiple chunks
  #   Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "chunk1")
  #   Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "chunk2")
  #   Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "chunk3")
  #
  #   connection = server.connections[connection_handle]
  #   stream = connection.get_stream(stream_id)
  #   assert_equal "chunk1chunk2chunk3", stream.buffer
  # end

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
