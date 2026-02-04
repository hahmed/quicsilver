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
    server = create_server(4433, {}, app)

    assert_instance_of Quicsilver::Server, server
  end

  def test_stop_when_not_running
    server = create_server

    assert_nil server.stop
    refute server.running?
  end

  def test_handle_stream_with_receive_event
    server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
    stream_id = 1
    connection_handle = 12345
    connection_data = [connection_handle, 67890]

    # Manually create connection
    connection = Quicsilver::Connection.new(connection_handle, connection_data)
    server.connections[connection_handle] = connection

    # Now test receive - data is buffered in Connection
    Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "test data")

    # Verify buffered data via complete_stream
    assert_equal "test data", connection.complete_stream(stream_id, "")
  end

  def test_handle_stream_accumulates_data
    server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
    stream_id = 1
    connection_handle = 12345
    connection_data = [connection_handle, 67890]

    # Manually create connection
    connection = Quicsilver::Connection.new(connection_handle, connection_data)
    server.connections[connection_handle] = connection

    # Send multiple chunks - data is buffered in Connection
    Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "chunk1")
    Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "chunk2")
    Quicsilver::Server.handle_stream(connection_data, stream_id, Quicsilver::Server::STREAM_EVENT_RECEIVE, "chunk3")

    # Verify accumulated data via complete_stream
    assert_equal "chunk1chunk2chunk3", connection.complete_stream(stream_id, "")
  end

  private

  def create_server(port=4433, options={}, app=nil)
    normalized_cert_file = options.delete(:cert_file) || cert_file_path
    normalized_key_file = options.delete(:key_file) || key_file_path

    server_config = options.delete(:server_configuration) || Quicsilver::ServerConfiguration.new(normalized_cert_file, normalized_key_file)
    Quicsilver::Server.new(port, server_configuration: server_config, app: app, **options)
  end
end
