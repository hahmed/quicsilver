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
end
