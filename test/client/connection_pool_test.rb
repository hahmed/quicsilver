# frozen_string_literal: true

require "test_helper"

# Unit tests for pool configuration and API surface.
# Pool behavior (reuse, eviction) is tested in integration/server_client_test.rb
# where real QUIC connections are available.
class ConnectionPoolTest < Minitest::Test
  parallelize_me!

  def test_default_config
    pool = Quicsilver::Client::ConnectionPool.new
    assert_equal 4, pool.max_size
    assert_equal 60, pool.idle_timeout
  end

  def test_custom_config
    pool = Quicsilver::Client::ConnectionPool.new(max_size: 10, idle_timeout: 120)
    assert_equal 10, pool.max_size
    assert_equal 120, pool.idle_timeout
  end

  def test_starts_empty
    pool = Quicsilver::Client::ConnectionPool.new
    assert_equal 0, pool.size
  end

  def test_client_pool_is_singleton
    assert_same Quicsilver::Client.pool, Quicsilver::Client.pool
  end

  def test_close_pool_creates_fresh_instance
    original = Quicsilver::Client.pool
    Quicsilver::Client.close_pool
    refute_same original, Quicsilver::Client.pool
  end

  def test_client_has_class_level_http_methods
    %i[get post patch delete head put request].each do |method|
      assert_respond_to Quicsilver::Client, method
    end
  end

  # Pooled connections are keyed on the options that shape the connection, so a
  # caller that wants certificate validation never receives a connection built
  # with unsecure: true.
  def test_connection_options_separate_pooled_connections
    pool = Quicsilver::Client::ConnectionPool.new

    refute_equal key(pool, unsecure: true), key(pool),
      "unsecure must not share a pooled connection with a validating caller"
    refute_equal key(pool, datagram_receive_enabled: false), key(pool)
    refute_equal key(pool, reliable_reset_enabled: false), key(pool)
    refute_equal key(pool, transport_cibir_id: "\x01\x02\x03\x04"), key(pool)
  end

  def test_options_matching_the_defaults_reuse_one_connection
    pool = Quicsilver::Client::ConnectionPool.new
    defaults = Quicsilver::Client::DEFAULT_CONNECTION_OPTIONS

    assert_equal key(pool), key(pool, **defaults)
  end

  # Per-request options must not fragment the pool.
  def test_request_options_do_not_separate_pooled_connections
    pool = Quicsilver::Client::ConnectionPool.new

    assert_equal key(pool), key(pool, request_timeout: 99)
    assert_equal key(pool), key(pool, max_body_size: 1024)
  end

  def test_different_hosts_and_ports_stay_separate
    pool = Quicsilver::Client::ConnectionPool.new

    refute_equal key(pool, host: "other.example.com"), key(pool)
    refute_equal key(pool, port: 4433), key(pool)
  end

  private

  def key(pool, host: "example.com", port: 443, **options)
    pool.send(:connection_key, host, port, options)
  end
end
