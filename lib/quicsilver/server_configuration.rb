# frozen_string_literal: true

module Quicsilver
  class ServerConfiguration
    attr_reader :cert_file, :key_file, :idle_timeout_ms, :server_resumption_level, :max_concurrent_requests,
      :max_unidirectional_streams, :stream_receive_window, :stream_receive_buffer, :connection_flow_control_window,
      :pacing_enabled, :send_buffering_enabled, :initial_rtt_ms, :initial_window_packets, :max_ack_delay_ms,
      :keep_alive_interval_ms, :congestion_control_algorithm, :migration_enabled,
      :disconnect_timeout_ms, :handshake_idle_timeout_ms

    QUIC_SERVER_RESUME_AND_ZERORTT = 1
    QUIC_SERVER_RESUME_ONLY = 2
    QUIC_SERVER_RESUME_AND_REUSE = 3
    QUIC_SERVER_RESUME_AND_REUSE_ZERORTT = 4

    # Congestion control algorithms
    CONGESTION_CONTROL_CUBIC = 0
    CONGESTION_CONTROL_BBR = 1

    DEFAULT_CERT_FILE = "certificates/server.crt"
    DEFAULT_KEY_FILE = "certificates/server.key"
    DEFAULT_ALPN = "h3"

    # Flow control defaults — cross-referenced with quiche, quic-go, lsquic, RFC 9000
    # See: https://github.com/microsoft/msquic/blob/main/docs/Settings.md
    DEFAULT_STREAM_RECEIVE_WINDOW = 262_144       # 256KB (quiche/quic-go use 1MB, MsQuic default 64KB)
    DEFAULT_STREAM_RECEIVE_BUFFER = 32_768        # 32KB (MsQuic default 4KB — too small for typical responses)
    DEFAULT_CONNECTION_FLOW_CONTROL_WINDOW = 16_777_216  # 16MB - connection-wide flow control

    # Throughput defaults
    DEFAULT_PACING_ENABLED = true              # RFC 9002: MUST pace or limit bursts
    DEFAULT_SEND_BUFFERING_ENABLED = true      # MsQuic recommended — coalesces small writes
    DEFAULT_INITIAL_RTT_MS = 100               # MsQuic default 333ms is satellite-grade; 100ms matches Chromium
    DEFAULT_INITIAL_WINDOW_PACKETS = 10        # Matches RFC 9002 recommendation
    DEFAULT_MAX_ACK_DELAY_MS = 25              # Matches RFC 9000 default

    # Connection management defaults
    DEFAULT_KEEP_ALIVE_INTERVAL_MS = 0         # 0 = disabled. Set to 20000 for NAT traversal
    DEFAULT_CONGESTION_CONTROL_ALGORITHM = CONGESTION_CONTROL_CUBIC  # CUBIC (0) or BBR (1)
    DEFAULT_MIGRATION_ENABLED = true           # Client IP migration. Disable behind load balancers
    DEFAULT_DISCONNECT_TIMEOUT_MS = 16_000     # How long to wait for ACK before path declared dead
    DEFAULT_HANDSHAKE_IDLE_TIMEOUT_MS = 10_000 # Handshake timeout (separate from connection idle)

    def initialize(cert_file = nil, key_file = nil, options = {})
      @idle_timeout_ms = options.fetch(:idle_timeout_ms, 10000)
      @server_resumption_level = options.fetch(:server_resumption_level, QUIC_SERVER_RESUME_AND_ZERORTT)
      @max_concurrent_requests = options.fetch(:max_concurrent_requests, 100)
      @max_unidirectional_streams = options.fetch(:max_unidirectional_streams, 10)
      @alpn = options.fetch(:alpn, DEFAULT_ALPN)

      # Flow control
      @stream_receive_window = options.fetch(:stream_receive_window, DEFAULT_STREAM_RECEIVE_WINDOW)
      @stream_receive_buffer = options.fetch(:stream_receive_buffer, DEFAULT_STREAM_RECEIVE_BUFFER)
      @connection_flow_control_window = options.fetch(:connection_flow_control_window, DEFAULT_CONNECTION_FLOW_CONTROL_WINDOW)

      # Throughput
      @pacing_enabled = options.fetch(:pacing_enabled, DEFAULT_PACING_ENABLED)
      @send_buffering_enabled = options.fetch(:send_buffering_enabled, DEFAULT_SEND_BUFFERING_ENABLED)
      @initial_rtt_ms = options.fetch(:initial_rtt_ms, DEFAULT_INITIAL_RTT_MS)
      @initial_window_packets = options.fetch(:initial_window_packets, DEFAULT_INITIAL_WINDOW_PACKETS)
      @max_ack_delay_ms = options.fetch(:max_ack_delay_ms, DEFAULT_MAX_ACK_DELAY_MS)

      # Connection management
      @keep_alive_interval_ms = options.fetch(:keep_alive_interval_ms, DEFAULT_KEEP_ALIVE_INTERVAL_MS)
      @congestion_control_algorithm = options.fetch(:congestion_control_algorithm, DEFAULT_CONGESTION_CONTROL_ALGORITHM)
      @migration_enabled = options.fetch(:migration_enabled, DEFAULT_MIGRATION_ENABLED)
      @disconnect_timeout_ms = options.fetch(:disconnect_timeout_ms, DEFAULT_DISCONNECT_TIMEOUT_MS)
      @handshake_idle_timeout_ms = options.fetch(:handshake_idle_timeout_ms, DEFAULT_HANDSHAKE_IDLE_TIMEOUT_MS)

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
        idle_timeout_ms: @idle_timeout_ms,
        server_resumption_level: @server_resumption_level,
        max_concurrent_requests: @max_concurrent_requests,
        max_unidirectional_streams: @max_unidirectional_streams,
        alpn: alpn,
        stream_receive_window: @stream_receive_window,
        stream_receive_buffer: @stream_receive_buffer,
        connection_flow_control_window: @connection_flow_control_window,
        pacing_enabled: @pacing_enabled ? 1 : 0,
        send_buffering_enabled: @send_buffering_enabled ? 1 : 0,
        initial_rtt_ms: @initial_rtt_ms,
        initial_window_packets: @initial_window_packets,
        max_ack_delay_ms: @max_ack_delay_ms,
        keep_alive_interval_ms: @keep_alive_interval_ms,
        congestion_control_algorithm: @congestion_control_algorithm,
        migration_enabled: @migration_enabled ? 1 : 0,
        disconnect_timeout_ms: @disconnect_timeout_ms,
        handshake_idle_timeout_ms: @handshake_idle_timeout_ms
      }
    end
  end
end