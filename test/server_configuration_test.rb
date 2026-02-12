require "test_helper"
require_relative "../lib/quicsilver/server_configuration"

class ServerConfigurationTest < Minitest::Test
  def test_default_initialization
    config = fetch_server_configuration_with_certs

    assert_equal cert_file_path, config.cert_file
    assert_equal key_file_path, config.key_file
    assert_equal 10000, config.idle_timeout
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, config.server_resumption_level
    assert_equal 10, config.max_concurrent_requests
    assert_equal 10, config.peer_unidi_stream_count
    assert_equal "h3", config.alpn
    assert_equal true, config.pacing_enabled
    assert_equal true, config.send_buffering_enabled
    assert_equal 333, config.initial_rtt_ms
    assert_equal 10, config.initial_window_packets
    assert_equal 25, config.max_ack_delay_ms
  end

  def test_initialization_with_custom_cert_files_raises_no_error_when_certs_does_not_exist
    assert_raises(Quicsilver::ServerConfigurationError) do
      Quicsilver::ServerConfiguration.new("missing.crt", "missing.key")
    end
  end

  def test_initialization_with_custom_cert_files_raises_no_error_when_key_does_not_exist
    assert_raises(Quicsilver::ServerConfigurationError) do
      Quicsilver::ServerConfiguration.new("certificates/server.crt", "missing.key")
    end
  end

  def test_initialization_with_options
    options = {
      idle_timeout: 5000,
      server_resumption_level: Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY,
      max_concurrent_requests: 20,
      peer_unidi_stream_count: 15,
      alpn: "h3-29"
    }
    
    config = fetch_server_configuration_with_certs(options)
    
    assert_equal 5000, config.idle_timeout
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY, config.server_resumption_level
    assert_equal 20, config.max_concurrent_requests
    assert_equal 15, config.peer_unidi_stream_count
    assert_equal "h3-29", config.alpn
  end

  def test_initialization_with_nil_values_in_options
    # Test that explicit nil values in options don't break the defaults
    options = {
      idle_timeout: nil,
      server_resumption_level: nil,
      max_concurrent_requests: nil,
      peer_unidi_stream_count: nil,
      alpn: nil
    }
    
    config = fetch_server_configuration_with_certs(options)
    
    # Should use defaults when nil is explicitly passed
    assert_equal 10000, config.idle_timeout
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, config.server_resumption_level
    assert_equal 10, config.max_concurrent_requests
    assert_equal 10, config.peer_unidi_stream_count
    assert_equal "h3", config.alpn
  end

  def test_initialization_with_false_values_in_options
    # Test that false values are preserved (not treated as nil)
    options = {
      idle_timeout: 1,
      server_resumption_level: false,
      max_concurrent_requests: false,
      peer_unidi_stream_count: false,
      alpn: false
    }
    
    config = fetch_server_configuration_with_certs(options)
    
    # Should preserve false values (not use defaults)
    assert_equal 1, config.idle_timeout
    assert_equal false, config.server_resumption_level
    assert_equal false, config.max_concurrent_requests
    assert_equal false, config.peer_unidi_stream_count
    assert_equal false, config.alpn
  end

  def test_to_h_method
    config = fetch_server_configuration_with_certs({
      idle_timeout: 5000,
      alpn: "h3-29"
    })
    
    hash = config.to_h
    
    assert_kind_of Hash, hash
    assert_equal cert_file_path, hash[:cert_file]
    assert_equal key_file_path, hash[:key_file]
    assert_equal 5000, hash[:idle_timeout]
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, hash[:server_resumption_level]
    assert_equal 10, hash[:peer_bidi_stream_count]
    assert_equal 10, hash[:peer_unidi_stream_count]
    assert_equal "h3-29", hash[:alpn]
  end

  def test_to_h_returns_symbol_keys
    config = fetch_server_configuration_with_certs
    hash = config.to_h

    # Ensure all keys are symbols (important for C extension compatibility)
    assert hash.key?(:cert_file)
    assert hash.key?(:key_file)
    assert hash.key?(:idle_timeout)
    assert hash.key?(:server_resumption_level)
    assert hash.key?(:peer_bidi_stream_count)
    assert hash.key?(:peer_unidi_stream_count)
    assert hash.key?(:alpn)
    assert hash.key?(:pacing_enabled)
    assert hash.key?(:send_buffering_enabled)
    assert hash.key?(:initial_rtt_ms)
    assert hash.key?(:initial_window_packets)
    assert hash.key?(:max_ack_delay_ms)

    # Ensure no string keys
    refute hash.key?("cert_file")
    refute hash.key?("key_file")
  end

  def test_to_h_no_nil_values
    config = fetch_server_configuration_with_certs
    hash = config.to_h
    
    # Ensure no nil values in the hash (critical for C extension)
    hash.each do |key, value|
      refute_nil value, "Hash value for #{key} should not be nil"
    end
  end

  def test_server_resumption_constants
    assert_equal 1, Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT
    assert_equal 2, Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY
    assert_equal 3, Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_REUSE
    assert_equal 4, Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_REUSE_ZERORTT
  end

  def test_alpn_getter_method
    config = fetch_server_configuration_with_certs({ alpn: "custom-protocol" })
    assert_equal "custom-protocol", config.alpn
  end

  def test_attr_readers_exist
    config = fetch_server_configuration_with_certs

    # Test that all expected attributes are readable
    assert_respond_to config, :cert_file
    assert_respond_to config, :key_file
    assert_respond_to config, :idle_timeout
    assert_respond_to config, :server_resumption_level
    assert_respond_to config, :max_concurrent_requests
    assert_respond_to config, :peer_unidi_stream_count
    assert_respond_to config, :alpn
    assert_respond_to config, :pacing_enabled
    assert_respond_to config, :send_buffering_enabled
    assert_respond_to config, :initial_rtt_ms
    assert_respond_to config, :initial_window_packets
    assert_respond_to config, :max_ack_delay_ms
  end

  private

  def fetch_server_configuration_with_certs(options={})
    Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path, options)
  end
end