# frozen_string_literal: true

module Quicsilver
  module HTTP3
    # HTTP/3 Frame Types (RFC 9114)
    FRAME_DATA = 0x00
    FRAME_HEADERS = 0x01
    FRAME_CANCEL_PUSH = 0x03
    FRAME_SETTINGS = 0x04
    FRAME_PUSH_PROMISE = 0x05
    FRAME_GOAWAY = 0x07
    FRAME_MAX_PUSH_ID = 0x0d

    # Frame types forbidden on request streams (RFC 9114 Section 7.2.4, 7.2.6, 7.2.7)
    CONTROL_ONLY_FRAMES = [FRAME_CANCEL_PUSH, FRAME_SETTINGS, FRAME_GOAWAY, FRAME_MAX_PUSH_ID].freeze

    FrameError = Class.new(StandardError)

    # HTTP/3 Error Codes (RFC 9114 Section 8.1)
    H3_NO_ERROR = 0x100
    H3_GENERAL_PROTOCOL_ERROR = 0x101
    H3_INTERNAL_ERROR = 0x102
    H3_STREAM_CREATION_ERROR = 0x103
    H3_CLOSED_CRITICAL_STREAM = 0x104
    H3_FRAME_UNEXPECTED = 0x105
    H3_FRAME_ERROR = 0x106
    H3_EXCESSIVE_LOAD = 0x107
    H3_ID_ERROR = 0x108
    H3_SETTINGS_ERROR = 0x109
    H3_MISSING_SETTINGS = 0x10a
    H3_REQUEST_REJECTED = 0x10b
    H3_REQUEST_CANCELLED = 0x10c
    H3_REQUEST_INCOMPLETE = 0x10d
    H3_MESSAGE_ERROR = 0x10e
    H3_CONNECT_ERROR = 0x10f
    H3_VERSION_FALLBACK = 0x110

    # QPACK Error Codes (RFC 9204 Section 6)
    QPACK_DECOMPRESSION_FAILED = 0x200
    QPACK_ENCODER_STREAM_ERROR = 0x201
    QPACK_DECODER_STREAM_ERROR = 0x202

    # QPACK Static Table Indices (RFC 9204 Appendix A)
    STATIC_TABLE = [
      [':authority', ''],                                      # 0
      [':path', '/'],                                          # 1
      ['age', '0'],                                            # 2
      ['content-disposition', ''],                             # 3
      ['content-length', '0'],                                 # 4
      ['cookie', ''],                                          # 5
      ['date', ''],                                            # 6
      ['etag', ''],                                            # 7
      ['if-modified-since', ''],                               # 8
      ['if-none-match', ''],                                   # 9
      ['last-modified', ''],                                   # 10
      ['link', ''],                                            # 11
      ['location', ''],                                        # 12
      ['referer', ''],                                         # 13
      ['set-cookie', ''],                                      # 14
      [':method', 'CONNECT'],                                  # 15
      [':method', 'DELETE'],                                   # 16
      [':method', 'GET'],                                      # 17
      [':method', 'HEAD'],                                     # 18
      [':method', 'OPTIONS'],                                  # 19
      [':method', 'POST'],                                     # 20
      [':method', 'PUT'],                                      # 21
      [':scheme', 'http'],                                     # 22
      [':scheme', 'https'],                                    # 23
      [':status', '103'],                                      # 24
      [':status', '200'],                                      # 25
      [':status', '304'],                                      # 26
      [':status', '404'],                                      # 27
      [':status', '503'],                                      # 28
      ['accept', '*/*'],                                       # 29
      ['accept', 'application/dns-message'],                   # 30
      ['accept-encoding', 'gzip, deflate, br'],                # 31
      ['accept-ranges', 'bytes'],                              # 32
      ['access-control-allow-headers', 'cache-control'],       # 33
      ['access-control-allow-headers', 'content-type'],        # 34
      ['access-control-allow-origin', '*'],                    # 35
      ['cache-control', 'max-age=0'],                          # 36
      ['cache-control', 'max-age=2592000'],                    # 37
      ['cache-control', 'max-age=604800'],                     # 38
      ['cache-control', 'no-cache'],                           # 39
      ['cache-control', 'no-store'],                           # 40
      ['cache-control', 'public, max-age=31536000'],           # 41
      ['content-encoding', 'br'],                              # 42
      ['content-encoding', 'gzip'],                            # 43
      ['content-type', 'application/dns-message'],             # 44
      ['content-type', 'application/javascript'],              # 45
      ['content-type', 'application/json'],                    # 46
      ['content-type', 'application/x-www-form-urlencoded'],   # 47
      ['content-type', 'image/gif'],                           # 48
      ['content-type', 'image/jpeg'],                          # 49
      ['content-type', 'image/png'],                           # 50
      ['content-type', 'text/css'],                            # 51
      ['content-type', 'text/html; charset=utf-8'],            # 52
      ['content-type', 'text/plain'],                          # 53
      ['content-type', 'text/plain;charset=utf-8'],            # 54
      ['range', 'bytes=0-'],                                   # 55
      ['strict-transport-security', 'max-age=31536000'],       # 56
      ['strict-transport-security', 'max-age=31536000; includesubdomains'], # 57
      ['strict-transport-security', 'max-age=31536000; includesubdomains; preload'], # 58
      ['vary', 'accept-encoding'],                             # 59
      ['vary', 'origin'],                                      # 60
      ['x-content-type-options', 'nosniff'],                   # 61
      ['x-xss-protection', '1; mode=block'],                   # 62
      [':status', '100'],                                      # 63
      [':status', '204'],                                      # 64
      [':status', '206'],                                      # 65
      [':status', '302'],                                      # 66
      [':status', '400'],                                      # 67
      [':status', '403'],                                      # 68
      [':status', '421'],                                      # 69
      [':status', '425'],                                      # 70
      [':status', '500'],                                      # 71
      ['accept-language', ''],                                 # 72
      ['access-control-allow-credentials', 'FALSE'],           # 73
      ['access-control-allow-credentials', 'TRUE'],            # 74
      ['access-control-allow-headers', '*'],                   # 75
      ['access-control-allow-methods', 'get'],                 # 76
      ['access-control-allow-methods', 'get, post, options'],  # 77
      ['access-control-allow-methods', 'options'],             # 78
      ['access-control-expose-headers', 'content-length'],     # 79
      ['access-control-request-headers', 'content-type'],      # 80
      ['access-control-request-method', 'get'],                # 81
      ['access-control-request-method', 'post'],               # 82
      ['alt-svc', 'clear'],                                    # 83
      ['authorization', ''],                                   # 84
      ['content-security-policy', "script-src 'none'; object-src 'none'; base-uri 'none'"], # 85
      ['early-data', '1'],                                     # 86
      ['expect-ct', ''],                                       # 87
      ['forwarded', ''],                                       # 88
      ['if-range', ''],                                        # 89
      ['origin', ''],                                          # 90
      ['purpose', 'prefetch'],                                 # 91
      ['server', ''],                                          # 92
      ['timing-allow-origin', '*'],                            # 93
      ['upgrade-insecure-requests', '1'],                      # 94
      ['user-agent', ''],                                      # 95
      ['x-forwarded-for', ''],                                 # 96
      ['x-frame-options', 'deny'],                             # 97
      ['x-frame-options', 'sameorigin']                        # 98
    ].freeze

    # Commonly used indices
    QPACK_AUTHORITY = 0
    QPACK_PATH = 1
    QPACK_CONTENT_LENGTH = 4
    QPACK_METHOD_CONNECT = 15
    QPACK_METHOD_DELETE = 16
    QPACK_METHOD_GET = 17
    QPACK_METHOD_HEAD = 18
    QPACK_METHOD_OPTIONS = 19
    QPACK_METHOD_POST = 20
    QPACK_METHOD_PUT = 21
    QPACK_SCHEME_HTTP = 22
    QPACK_SCHEME_HTTPS = 23
    QPACK_STATUS_200 = 25
    QPACK_STATUS_404 = 27
    QPACK_STATUS_500 = 71
    QPACK_STATUS_400 = 67
    QPACK_CONTENT_TYPE_JSON = 46
    QPACK_CONTENT_TYPE_PLAIN = 53

    # Maximum stream ID for initial GOAWAY (2^62 - 4, per RFC 9114)
    MAX_STREAM_ID = (2**62) - 4

    class << self
      # Encode variable-length integer
      def encode_varint(value)
        case value
        when 0..63
          [value].pack('C')
        when 64..16383
          [0x40 | (value >> 8), value & 0xFF].pack('C*')
        when 16384..1073741823
          [0x80 | (value >> 24), (value >> 16) & 0xFF,
          (value >> 8) & 0xFF, value & 0xFF].pack('C*')
        else
          [0xC0 | (value >> 56), (value >> 48) & 0xFF,
          (value >> 40) & 0xFF, (value >> 32) & 0xFF,
          (value >> 24) & 0xFF, (value >> 16) & 0xFF,
          (value >> 8) & 0xFF, value & 0xFF].pack('C*')
        end
      end

      def build_settings_frame(settings = {})
        payload = ""
        settings.each do |id, value|
          payload += encode_varint(id)
          payload += encode_varint(value)
        end

        frame_type = encode_varint(FRAME_SETTINGS)
        frame_length = encode_varint(payload.bytesize)

        frame_type + frame_length + payload
      end

      # Build control stream data
      def build_control_stream
        stream_type = [0x00].pack('C')  # Control stream type
        settings = build_settings_frame({
          0x01 => 0,  # QPACK_MAX_TABLE_CAPACITY = 0 (no dynamic table)
          0x07 => 0   # QPACK_BLOCKED_STREAMS = 0
        })

        stream_type + settings
      end

      # Build GOAWAY frame (RFC 9114 Section 7.2.6)
      # stream_id: The last client-initiated bidirectional stream ID the server will process
      def build_goaway_frame(stream_id)
        frame_type = encode_varint(FRAME_GOAWAY)
        payload = encode_varint(stream_id)
        frame_length = encode_varint(payload.bytesize)

        frame_type + frame_length + payload
      end

      # Decode variable-length integer (RFC 9000)
      # Returns [value, bytes_consumed]
      def decode_varint(bytes, offset = 0)
        return [0, 0] if offset >= bytes.size

        first = bytes[offset]
        return [0, 0] if first.nil?

        prefix = (first & 0xC0) >> 6 # Extract 2 MSB
        length = 1 << prefix # 1, 2, 4, or 8 bytes

        # Check if we have enough bytes
        return [0, 0] if offset + length > bytes.size

        case prefix
        when 0
          [first & 0x3F, 1]
        when 1
          [(first & 0x3F) << 8 | bytes[offset + 1], 2]
        when 2
          [(first & 0x3F) << 24 | bytes[offset + 1] << 16 |
          bytes[offset + 2] << 8 | bytes[offset + 3], 4]
        else # when 3
          [(first & 0x3F) << 56 | bytes[offset + 1] << 48 |
          bytes[offset + 2] << 40 | bytes[offset + 3] << 32 |
          bytes[offset + 4] << 24 | bytes[offset + 5] << 16 |
            bytes[offset + 6] << 8 | bytes[offset + 7], 8]
        end
      end
    end
  end
end

