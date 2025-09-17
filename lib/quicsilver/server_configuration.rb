# frozen_string_literal: true
 
module Quicsilver
  class ServerConfiguration
    attr_reader :cert_file, :key_file, :idle_timeout, :server_resumption_level, :peer_bidi_stream_count, 
      :peer_unidi_stream_count

    QUIC_SERVER_RESUME_AND_ZERORTT = 1
    QUIC_SERVER_RESUME_ONLY = 2
    QUIC_SERVER_RESUME_AND_REUSE = 3
    QUIC_SERVER_RESUME_AND_REUSE_ZERORTT = 4

    def initialize(cert_file = nil, key_file = nil, options = {})
      @cert_file = cert_file.nil? ? "certs/server.crt" : cert_file
      @key_file = key_file.nil? ? "certs/server.key" : key_file
      @idle_timeout = options[:idle_timeout].nil? ? 10000 : options[:idle_timeout]
      @server_resumption_level = options[:server_resumption_level].nil? ? QUIC_SERVER_RESUME_AND_ZERORTT : options[:server_resumption_level]
      @peer_bidi_stream_count = options[:peer_bidi_stream_count].nil? ? 10 : options[:peer_bidi_stream_count]
      @peer_unidi_stream_count = options[:peer_unidi_stream_count].nil? ? 10 : options[:peer_unidi_stream_count]
      @alpn = options[:alpn].nil? ? "h3" : options[:alpn]
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
        alpn: alpn
      }
    end
  end
end