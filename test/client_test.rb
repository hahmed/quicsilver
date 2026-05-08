# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  parallelize_me!
  def test_initialize_with_hostname_and_port
    client = Quicsilver::Client.new("localhost", 4433)

    assert_equal "localhost", client.hostname
    assert_equal 4433, client.port
  end

  def test_initialize_with_default_port
    client = Quicsilver::Client.new("example.com")

    assert_equal "example.com", client.hostname
    assert_equal 4433, client.port
  end

  def test_initialize_with_options
    client = Quicsilver::Client.new("test.com", 9999, unsecure: false, connection_timeout: 10000)

    assert_equal "test.com", client.hostname
    assert_equal 9999, client.port
    assert_equal false, client.unsecure
    assert_equal 10000, client.connection_timeout
  end

  def test_initialize_with_defaults
    client = Quicsilver::Client.new("localhost", 4433)

    assert_equal true, client.unsecure
    assert_equal 5000, client.connection_timeout
  end

  def test_connected_returns_false_initially
    client = Quicsilver::Client.new("localhost", 4433)

    refute client.connected?
  end

  def test_connection_info_returns_hash_with_details
    client = Quicsilver::Client.new("localhost", 4433)

    info = client.connection_info

    assert_instance_of Hash, info
    assert_equal "localhost", info[:hostname]
    assert_equal 4433, info[:port]
    assert_equal 0, info[:uptime]
  end

  def test_connection_uptime_returns_zero_when_not_connected
    client = Quicsilver::Client.new("localhost", 4433)

    assert_equal 0, client.connection_uptime
  end

  def test_disconnect_when_not_connected
    client = Quicsilver::Client.new("localhost", 4433)

    assert_nil client.disconnect
  end

  # 1xx informational and trailer tests are in test/integration/server_client_test.rb
  # (real server→client, no mocked internals)

  def test_transport_error_parses_hex_status
    assert_equal 1, Quicsilver::TransportError.parse_status("StreamOpen failed, 0x1!")    # EPERM / INVALID_STATE
    assert_equal 12, Quicsilver::TransportError.parse_status("StreamOpen failed, 0xc!")   # ENOMEM / OUT_OF_MEMORY
    assert_equal 0x56, Quicsilver::TransportError.parse_status("StreamStart failed, 0x56!") # ESTRPIPE / STREAM_LIMIT_REACHED
    assert_equal 0, Quicsilver::TransportError.parse_status("no hex here")
    assert_equal 0, Quicsilver::TransportError.parse_status(nil)
  end

  def test_stream_failed_to_open_error_is_a_transport_error
    err = Quicsilver::StreamFailedToOpenError.new("test", status: 0x59)
    assert_kind_of Quicsilver::TransportError, err
    assert_kind_of Quicsilver::Error, err
    assert_equal 0x59, err.status
  end
end

class ClientOpenStreamErrorTest < Minitest::Test
  def test_open_stream_wraps_stream_open_failure
    client = Quicsilver::Client.new("localhost", 4433)
    client.instance_variable_set(:@connection_data, [1, 2])

    original_open = Quicsilver.method(:open_stream)
    Quicsilver.define_singleton_method(:open_stream) do |*_args|
      raise RuntimeError, "StreamOpen failed, 0x1!"
    end

    err = assert_raises(Quicsilver::StreamFailedToOpenError) { client.send(:open_stream) }
    assert_match(/StreamOpen failed/, err.message)
    assert_equal 1, err.status  # EPERM / QUIC_STATUS_INVALID_STATE
  ensure
    Quicsilver.define_singleton_method(:open_stream, original_open)
  end

  def test_open_stream_wraps_allocation_failure
    client = Quicsilver::Client.new("localhost", 4433)
    client.instance_variable_set(:@connection_data, [1, 2])

    original_open = Quicsilver.method(:open_stream)
    Quicsilver.define_singleton_method(:open_stream) do |*_args|
      raise RuntimeError, "Failed to allocate stream context"
    end

    err = assert_raises(Quicsilver::TransportError) { client.send(:open_stream) }
    assert_match(/Failed to allocate/, err.message)
  ensure
    Quicsilver.define_singleton_method(:open_stream, original_open)
  end

  def test_open_stream_passes_through_unknown_errors
    client = Quicsilver::Client.new("localhost", 4433)
    client.instance_variable_set(:@connection_data, [1, 2])

    original_open = Quicsilver.method(:open_stream)
    Quicsilver.define_singleton_method(:open_stream) do |*_args|
      raise RuntimeError, "Something unexpected"
    end

    assert_raises(RuntimeError) { client.send(:open_stream) }
  ensure
    Quicsilver.define_singleton_method(:open_stream, original_open)
  end
end
