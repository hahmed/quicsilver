# frozen_string_literal: true

require "test_helper"
require_relative "../lib/quicsilver/client"

class ClientTest < Minitest::Test
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
end
