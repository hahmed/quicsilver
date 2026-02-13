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

  # Regression: C packs STREAM_RESET data as [handle(8)][error_code(8)].
  # Server must skip the handle prefix to read the error code correctly.
  def test_handle_stream_reset_parses_error_code_from_packed_data
    logged_messages = []
    Quicsilver.logger.stub(:debug, ->(msg) { logged_messages << msg }) do
      server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
      connection_handle = 12345
      connection_data = [connection_handle, 67890]

      connection = Quicsilver::Connection.new(connection_handle, connection_data)
      server.connections[connection_handle] = connection

      stream_id = 4
      server.request_registry.track(stream_id, connection_handle, path: "/test", method: "GET")

      # C sends [handle(8)][error_code(8)]
      fake_handle = 0xDEADBEEF
      error_code = 0x10c
      packed_data = [fake_handle, error_code].pack("QQ")

      Quicsilver::Server.handle_stream(connection_data, stream_id, "STREAM_RESET", packed_data)

      assert server.request_registry.empty?, "Request should be cleaned up after STREAM_RESET"

      reset_log = logged_messages.find { |m| m.include?("reset") }
      assert reset_log, "Should log the reset event"
      assert_includes reset_log, "0x10c", "Should log the correct error code, not the handle"
    end
  end

  # STOP_SENDING compliance: server must mark stream as cancelled and reset it
  def test_stop_sending_cancels_stream
    server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
    connection_handle = 12345
    connection_data = [connection_handle, 67890]

    connection = Quicsilver::Connection.new(connection_handle, connection_data)
    server.connections[connection_handle] = connection

    stream_id = 4
    stream_handle = 0xABCD
    packed_data = [stream_handle, Quicsilver::HTTP3::H3_REQUEST_CANCELLED].pack("QQ")

    Quicsilver.stub(:stream_reset, ->(*args) { true }) do
      Quicsilver::Server.handle_stream(connection_data, stream_id, "STOP_SENDING", packed_data)
    end

    assert server.cancelled_stream?(stream_id), "Stream should be marked as cancelled after STOP_SENDING"
  end

  # STOP_SENDING compliance: server resets the send side of the stream
  def test_stop_sending_resets_stream
    server = create_server(4433, app: ->(env) { [200, {}, ["OK"]] })
    connection_handle = 12345
    connection_data = [connection_handle, 67890]

    connection = Quicsilver::Connection.new(connection_handle, connection_data)
    server.connections[connection_handle] = connection

    stream_id = 4
    stream_handle = 0xABCD
    packed_data = [stream_handle, Quicsilver::HTTP3::H3_REQUEST_CANCELLED].pack("QQ")

    reset_called_with = nil
    Quicsilver.stub(:stream_reset, ->(*args) { reset_called_with = args; true }) do
      Quicsilver::Server.handle_stream(connection_data, stream_id, "STOP_SENDING", packed_data)
    end

    assert_equal [stream_handle, Quicsilver::HTTP3::H3_REQUEST_CANCELLED], reset_called_with,
      "Should reset the stream with H3_REQUEST_CANCELLED"
  end

  def test_default_max_queue_size
    server = create_server_direct(threads: 5)
    assert_equal 20, server.max_queue_size
  end

  def test_custom_max_queue_size
    server = create_server_direct(threads: 5, max_queue_size: 100)
    assert_equal 100, server.max_queue_size
  end

  def test_dispatch_sends_503_when_queue_full
    server = create_server_direct(threads: 1, max_queue_size: 1, app: ->(env) { [200, {}, ["OK"]] })

    connection_handle = 12345
    connection_data = [connection_handle, 67890]
    connection = Quicsilver::Connection.new(connection_handle, connection_data)
    server.connections[connection_handle] = connection

    # Fill the queue so next dispatch overflows
    server.send(:work_queue).push([:dummy, :work])

    stream = Quicsilver::QuicStream.new(4)
    stream.stream_handle = 0xBEEF

    error_sent = nil
    connection.stub(:send_error, ->(s, status, msg) { error_sent = [status, msg] }) do
      server.send(:dispatch_request, connection, stream)
    end

    assert_equal [503, "Service Unavailable"], error_sent
  end

  def test_default_max_connections
    server = create_server_direct
    assert_equal 100, server.max_connections
  end

  def test_custom_max_connections
    server = create_server_direct(max_connections: 50)
    assert_equal 50, server.max_connections
  end

  def test_rejects_connection_at_limit
    server = create_server_direct(max_connections: 1, app: ->(env) { [200, {}, ["OK"]] })

    # Pre-fill to limit
    connection = Quicsilver::Connection.new(12345, [12345, 67890])
    server.connections[12345] = connection

    new_handle = 99999
    new_data = [new_handle, 11111]

    shutdown_called = false
    Quicsilver.stub(:connection_shutdown, ->(*args) { shutdown_called = true }) do
      server.handle_stream_event(new_data, 0, "CONNECTION_ESTABLISHED", nil)
    end

    assert shutdown_called, "Should shutdown excess connection"
    assert_nil server.connections[new_handle], "Should not add connection beyond limit"
  end

  def test_signal_handlers_installed
    server = create_server_direct
    server.send(:setup_signal_handlers)

    # Verify traps are set by checking they return the previous handler
    old_int = trap("INT", "DEFAULT")
    old_term = trap("TERM", "DEFAULT")

    refute_nil old_int
    refute_nil old_term
  ensure
    trap("INT", "DEFAULT")
    trap("TERM", "DEFAULT")
  end

  def test_dispatch_queues_when_under_limit
    server = create_server_direct(threads: 1, max_queue_size: 5, app: ->(env) { [200, {}, ["OK"]] })

    connection_handle = 12345
    connection_data = [connection_handle, 67890]
    connection = Quicsilver::Connection.new(connection_handle, connection_data)
    server.connections[connection_handle] = connection

    stream = Quicsilver::QuicStream.new(4)
    stream.stream_handle = 0xBEEF

    server.send(:dispatch_request, connection, stream)

    assert_equal 1, server.send(:work_queue).size
  end

  private

  def create_server(port=4433, options={}, app=nil)
    normalized_cert_file = options.delete(:cert_file) || cert_file_path
    normalized_key_file = options.delete(:key_file) || key_file_path

    server_config = options.delete(:server_configuration) || Quicsilver::ServerConfiguration.new(normalized_cert_file, normalized_key_file)
    Quicsilver::Server.new(port, server_configuration: server_config, app: app, **options)
  end

  def create_server_direct(**kwargs)
    config = Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path)
    Quicsilver::Server.new(4433, server_configuration: config, **kwargs)
  end
end
