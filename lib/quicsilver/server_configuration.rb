# frozen_string_literal: true

require "localhost"

module Quicsilver
  class ServerConfiguration
    attr_reader :cert_file, :key_file, :idle_timeout, :server_resumption_level, :max_concurrent_requests,
      :peer_unidi_stream_count, :stream_recv_window, :stream_recv_buffer, :conn_flow_control_window

    QUIC_SERVER_RESUME_AND_ZERORTT = 1
    QUIC_SERVER_RESUME_ONLY = 2
    QUIC_SERVER_RESUME_AND_REUSE = 3
    QUIC_SERVER_RESUME_AND_REUSE_ZERORTT = 4

    DEFAULT_CERT_FILE = "certificates/server.crt"
    DEFAULT_KEY_FILE = "certificates/server.key"
    DEFAULT_ALPN = "h3"

    # Flow control defaults (msquic defaults)
    # See: https://github.com/microsoft/msquic/blob/main/docs/Settings.md
    DEFAULT_STREAM_RECV_WINDOW = 65_536        # 64KB - initial stream receive window
    DEFAULT_STREAM_RECV_BUFFER = 4_096         # 4KB - stream buffer size
    DEFAULT_CONN_FLOW_CONTROL_WINDOW = 16_777_216  # 16MB - connection-wide flow control

    def initialize(cert_file = nil, key_file = nil, options = {})
      @idle_timeout = options[:idle_timeout].nil? ? 10000 : options[:idle_timeout]
      @server_resumption_level = options[:server_resumption_level].nil? ? QUIC_SERVER_RESUME_AND_ZERORTT : options[:server_resumption_level]
      @max_concurrent_requests = options[:max_concurrent_requests].nil? ? 10 : options[:max_concurrent_requests]
      @peer_unidi_stream_count = options[:peer_unidi_stream_count].nil? ? 10 : options[:peer_unidi_stream_count]
      @alpn = options[:alpn].nil? ? DEFAULT_ALPN : options[:alpn]

      # Flow control / backpressure settings
      @stream_recv_window = options[:stream_recv_window].nil? ? DEFAULT_STREAM_RECV_WINDOW : options[:stream_recv_window]
      @stream_recv_buffer = options[:stream_recv_buffer].nil? ? DEFAULT_STREAM_RECV_BUFFER : options[:stream_recv_buffer]
      @conn_flow_control_window = options[:conn_flow_control_window].nil? ? DEFAULT_CONN_FLOW_CONTROL_WINDOW : options[:conn_flow_control_window]

      @cert_file = cert_file.nil? ? DEFAULT_CERT_FILE : cert_file
      @key_file = key_file.nil? ? DEFAULT_KEY_FILE : key_file

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
        peer_bidi_stream_count: @max_concurrent_requests,
        peer_unidi_stream_count: @peer_unidi_stream_count,
        alpn: alpn,
        stream_recv_window: @stream_recv_window,
        stream_recv_buffer: @stream_recv_buffer,
        conn_flow_control_window: @conn_flow_control_window
      }
    end
  end
end