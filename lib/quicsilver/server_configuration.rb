# frozen_string_literal: true

require "localhost"

module Quicsilver
  class ServerConfiguration
    attr_reader :cert_file, :key_file, :idle_timeout, :server_resumption_level, :peer_bidi_stream_count,
      :peer_unidi_stream_count, :stream_recv_window, :stream_recv_buffer, :conn_flow_control_window

    QUIC_SERVER_RESUME_AND_ZERORTT = 1
    QUIC_SERVER_RESUME_ONLY = 2
    QUIC_SERVER_RESUME_AND_REUSE = 3
    QUIC_SERVER_RESUME_AND_REUSE_ZERORTT = 4

    DEFAULT_CERT_FILE = "certificates/server.crt"
    DEFAULT_KEY_FILE = "certificates/server.key"
    DEFAULT_ALPN = "h3"

    def initialize(cert_file = nil, key_file = nil, options = {})
      defaults = Quicsilver.config

      @idle_timeout = option_or_default(options, :idle_timeout, defaults.idle_timeout)
      @server_resumption_level = option_or_default(options, :server_resumption_level, QUIC_SERVER_RESUME_AND_ZERORTT)
      @peer_bidi_stream_count = option_or_default(options, :peer_bidi_stream_count, defaults.max_streams)
      @peer_unidi_stream_count = option_or_default(options, :peer_unidi_stream_count, defaults.max_streams)
      @alpn = option_or_default(options, :alpn, DEFAULT_ALPN)

      # Flow control / backpressure settings
      @stream_recv_window = option_or_default(options, :stream_window_size, defaults.stream_window_size)
      @stream_recv_buffer = option_or_default(options, :stream_buffer_size, defaults.stream_buffer_size)
      @conn_flow_control_window = option_or_default(options, :connection_window_size, defaults.connection_window_size)

      @cert_file = cert_file || DEFAULT_CERT_FILE
      @key_file = key_file || DEFAULT_KEY_FILE

      unless File.exist?(@cert_file)
        raise ServerConfigurationError, "Certificate file not found: #{@cert_file}"
      end

      unless File.exist?(@key_file)
        raise ServerConfigurationError, "Key file not found: #{@key_file}"
      end
    end

    # Common HTTP/3 ALPN Values:
    # "h3" - HTTP/3 (most common)
    # "h3-29" - HTTP/3 draft version 29
    # "h3-28" - HTTP/3 draft version 28
    # "h3-27" - HTTP/3 draft version 27
    # Other QUIC ALPN Values:
    # "hq-interop" - HTTP/0.9 over QUIC (testing)
    # "hq-29" - HTTP/0.9 over QUIC draft 29
    # "doq" - DNS over QUIC
    # "doq-i03" - DNS over QUIC draft
    def alpn
      @alpn
    end

    def to_h
      {
        cert_file: @cert_file,
        key_file: @key_file,
        idle_timeout: @idle_timeout,
        server_resumption_level: @server_resumption_level,
        peer_bidi_stream_count: @peer_bidi_stream_count,
        peer_unidi_stream_count: @peer_unidi_stream_count,
        alpn: alpn,
        stream_recv_window: @stream_recv_window,
        stream_recv_buffer: @stream_recv_buffer,
        conn_flow_control_window: @conn_flow_control_window
      }
    end

    private

    # Returns option value if present and non-nil, otherwise default.
    # Preserves explicit false values.
    def option_or_default(options, key, default)
      options.key?(key) && !options[key].nil? ? options[key] : default
    end
  end
end