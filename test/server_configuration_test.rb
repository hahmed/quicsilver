require "test_helper"

# Test only the ServerConfiguration class without loading the full quicsilver gem
# This avoids C extension compatibility issues
require_relative "../lib/quicsilver/server_configuration"

class ServerConfigurationTest < Minitest::Test
  def test_default_initialization
    config = Quicsilver::ServerConfiguration.new
    
    assert_equal "certs/server.crt", config.cert_file
    assert_equal "certs/server.key", config.key_file
    assert_equal 10000, config.idle_timeout
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, config.server_resumption_level
    assert_equal 10, config.peer_bidi_stream_count
    assert_equal 10, config.peer_unidi_stream_count
    assert_equal "h3", config.alpn
  end

  def test_initialization_with_custom_cert_files
    config = Quicsilver::ServerConfiguration.new("custom.crt", "custom.key")
    
    assert_equal "custom.crt", config.cert_file
    assert_equal "custom.key", config.key_file
  end

  def test_initialization_with_options
    options = {
      idle_timeout: 5000,
      server_resumption_level: Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY,
      peer_bidi_stream_count: 20,
      peer_unidi_stream_count: 15,
      alpn: "h3-29"
    }
    
    config = Quicsilver::ServerConfiguration.new(nil, nil, options)
    
    assert_equal 5000, config.idle_timeout
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_ONLY, config.server_resumption_level
    assert_equal 20, config.peer_bidi_stream_count
    assert_equal 15, config.peer_unidi_stream_count
    assert_equal "h3-29", config.alpn
  end

  def test_initialization_with_nil_values_in_options
    # Test that explicit nil values in options don't break the defaults
    options = {
      idle_timeout: nil,
      server_resumption_level: nil,
      peer_bidi_stream_count: nil,
      peer_unidi_stream_count: nil,
      alpn: nil
    }
    
    config = Quicsilver::ServerConfiguration.new(nil, nil, options)
    
    # Should use defaults when nil is explicitly passed
    assert_equal 10000, config.idle_timeout
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, config.server_resumption_level
    assert_equal 10, config.peer_bidi_stream_count
    assert_equal 10, config.peer_unidi_stream_count
    assert_equal "h3", config.alpn
  end

  def test_initialization_with_false_values_in_options
    # Test that false values are preserved (not treated as nil)
    options = {
      idle_timeout: false,
      server_resumption_level: false,
      peer_bidi_stream_count: false,
      peer_unidi_stream_count: false,
      alpn: false
    }
    
    config = Quicsilver::ServerConfiguration.new(nil, nil, options)
    
    # Should preserve false values (not use defaults)
    assert_equal false, config.idle_timeout
    assert_equal false, config.server_resumption_level
    assert_equal false, config.peer_bidi_stream_count
    assert_equal false, config.peer_unidi_stream_count
    assert_equal false, config.alpn
  end

  def test_initialization_with_empty_string_values
    # Test that empty strings are preserved
    options = {
      alpn: ""
    }
    
    config = Quicsilver::ServerConfiguration.new("", "", options)
    
    assert_equal "", config.cert_file
    assert_equal "", config.key_file
    assert_equal "", config.alpn
  end

  def test_to_h_method
    config = Quicsilver::ServerConfiguration.new("test.crt", "test.key", {
      idle_timeout: 5000,
      alpn: "h3-29"
    })
    
    hash = config.to_h
    
    assert_kind_of Hash, hash
    assert_equal "test.crt", hash[:cert_file]
    assert_equal "test.key", hash[:key_file]
    assert_equal 5000, hash[:idle_timeout]
    assert_equal Quicsilver::ServerConfiguration::QUIC_SERVER_RESUME_AND_ZERORTT, hash[:server_resumption_level]
    assert_equal 10, hash[:peer_bidi_stream_count]
    assert_equal 10, hash[:peer_unidi_stream_count]
    assert_equal "h3-29", hash[:alpn]
  end

  def test_to_h_returns_symbol_keys
    config = Quicsilver::ServerConfiguration.new
    hash = config.to_h
    
    # Ensure all keys are symbols (important for C extension compatibility)
    assert hash.key?(:cert_file)
    assert hash.key?(:key_file)
    assert hash.key?(:idle_timeout)
    assert hash.key?(:server_resumption_level)
    assert hash.key?(:peer_bidi_stream_count)
    assert hash.key?(:peer_unidi_stream_count)
    assert hash.key?(:alpn)
    
    # Ensure no string keys
    refute hash.key?("cert_file")
    refute hash.key?("key_file")
  end

  def test_to_h_no_nil_values
    config = Quicsilver::ServerConfiguration.new
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
    config = Quicsilver::ServerConfiguration.new(nil, nil, { alpn: "custom-protocol" })
    assert_equal "custom-protocol", config.alpn
  end

  def test_attr_readers_exist
    config = Quicsilver::ServerConfiguration.new
    
    # Test that all expected attributes are readable
    assert_respond_to config, :cert_file
    assert_respond_to config, :key_file
    assert_respond_to config, :idle_timeout
    assert_respond_to config, :server_resumption_level
    assert_respond_to config, :peer_bidi_stream_count
    assert_respond_to config, :peer_unidi_stream_count
    assert_respond_to config, :alpn
  end
end