require "test_helper"
require_relative "../lib/quicsilver/server_configuration"

class ServerConfigurationTest < Minitest::Test
  def test_default_initialization
    config = fetch_server_configuration_with_certs

    assert_equal cert_file_path, config.cert_file
    assert_equal key_file_path, config.key_file
    assert_equal 10000, config.idle_timeout_ms
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, config.server_resumption_level
    assert_equal 100, config.max_concurrent_requests
    assert_equal 10, config.max_unidirectional_streams
    assert_equal "h3", config.alpn
    assert_equal true, config.pacing_enabled
    assert_equal true, config.send_buffering_enabled
    assert_equal 100, config.initial_rtt_ms
    assert_equal 10, config.initial_window_packets
    assert_equal 25, config.max_ack_delay_ms
    assert_equal 0, config.keep_alive_interval_ms
    assert_equal Quicsilver::ServerConfiguration::CONGESTION_CONTROL_CUBIC, config.congestion_control_algorithm
    assert_equal true, config.migration_enabled
    assert_equal 16_000, config.disconnect_timeout_ms
    assert_equal 10_000, config.handshake_idle_timeout_ms
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
      idle_timeout_ms: 5000,
      server_resumption_level: Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY,
      max_concurrent_requests: 20,
      max_unidirectional_streams: 15,
      alpn: "h3-29"
    }
    
    config = fetch_server_configuration_with_certs(options)
    
    assert_equal 5000, config.idle_timeout_ms
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY, config.server_resumption_level
    assert_equal 20, config.max_concurrent_requests
    assert_equal 15, config.max_unidirectional_streams
    assert_equal "h3-29", config.alpn
  end

  def test_initialization_with_nil_values_in_options
    options = {
      idle_timeout_ms: nil,
      server_resumption_level: nil,
      max_concurrent_requests: nil,
      max_unidirectional_streams: nil,
      alpn: nil,
      keep_alive_interval_ms: nil,
      congestion_control_algorithm: nil,
      migration_enabled: nil
    }

    config = fetch_server_configuration_with_certs(options)

    # Explicit nil means nil — fetch doesn't override caller intent
    assert_nil config.idle_timeout_ms
    assert_nil config.server_resumption_level
    assert_nil config.max_concurrent_requests
    assert_nil config.max_unidirectional_streams
    assert_nil config.alpn
    assert_nil config.keep_alive_interval_ms
    assert_nil config.congestion_control_algorithm
    assert_nil config.migration_enabled
  end

  def test_initialization_with_false_values_in_options
    # Test that false values are preserved (not treated as nil)
    options = {
      idle_timeout_ms: 1,
      server_resumption_level: false,
      max_concurrent_requests: false,
      max_unidirectional_streams: false,
      alpn: false
    }
    
    config = fetch_server_configuration_with_certs(options)
    
    # Should preserve false values (not use defaults)
    assert_equal 1, config.idle_timeout_ms
    assert_equal false, config.server_resumption_level
    assert_equal false, config.max_concurrent_requests
    assert_equal false, config.max_unidirectional_streams
    assert_equal false, config.alpn
  end

  def test_to_h_method
    config = fetch_server_configuration_with_certs({
      idle_timeout_ms: 5000,
      alpn: "h3-29",
      keep_alive_interval_ms: 20000,
      congestion_control_algorithm: Quicsilver::ServerConfiguration::CONGESTION_CONTROL_BBR,
      migration_enabled: false
    })

    hash = config.to_h

    assert_kind_of Hash, hash
    assert_equal cert_file_path, hash[:cert_file]
    assert_equal key_file_path, hash[:key_file]
    assert_equal 5000, hash[:idle_timeout_ms]
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, hash[:server_resumption_level]
    assert_equal 100, hash[:max_concurrent_requests]
    assert_equal 10, hash[:max_unidirectional_streams]
    assert_equal "h3-29", hash[:alpn]
    assert_equal 20000, hash[:keep_alive_interval_ms]
    assert_equal Quicsilver::ServerConfiguration::CONGESTION_CONTROL_BBR, hash[:congestion_control_algorithm]
    assert_equal 0, hash[:migration_enabled]
  end

  def test_to_h_returns_symbol_keys
    config = fetch_server_configuration_with_certs
    hash = config.to_h

    expected_keys = %i[
      cert_file key_file idle_timeout_ms server_resumption_level
      max_concurrent_requests max_unidirectional_streams alpn
      stream_receive_window stream_receive_buffer connection_flow_control_window
      pacing_enabled send_buffering_enabled initial_rtt_ms
      initial_window_packets max_ack_delay_ms
      keep_alive_interval_ms congestion_control_algorithm migration_enabled
      disconnect_timeout_ms handshake_idle_timeout_ms
    ]

    expected_keys.each { |k| assert hash.key?(k), "Missing key: #{k}" }

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

    expected_attrs = %i[
      cert_file key_file idle_timeout_ms server_resumption_level
      max_concurrent_requests max_unidirectional_streams alpn
      stream_receive_window stream_receive_buffer connection_flow_control_window
      pacing_enabled send_buffering_enabled initial_rtt_ms
      initial_window_packets max_ack_delay_ms
      keep_alive_interval_ms congestion_control_algorithm migration_enabled
      disconnect_timeout_ms handshake_idle_timeout_ms
    ]

    expected_attrs.each { |a| assert_respond_to config, a, "Missing attr_reader: #{a}" }
  end

  private

  def fetch_server_configuration_with_certs(options={})
    Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path, options)
  end
end