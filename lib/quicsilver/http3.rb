# frozen_string_literal: true

module Quicsilver
  module HTTP3
    # Encode variable-length integer
    def self.encode_varint(value)
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

    def self.build_settings_frame(settings = {})
      payload = ""
      settings.each do |id, value|
        payload += encode_varint(id)
        payload += encode_varint(value)
      end

      frame_type = encode_varint(0x04)  # SETTINGS
      frame_length = encode_varint(payload.bytesize)

      frame_type + frame_length + payload
    end

    # Build control stream data
    def self.build_control_stream
      stream_type = [0x00].pack('C')  # Control stream type
      settings = build_settings_frame({
        # 0x01 => 4096,  # QPACK_MAX_TABLE_CAPACITY (optional)
        # 0x06 => 16384  # MAX_HEADER_LIST_SIZE (optional)
      })

      stream_type + settings
    end

    # Decode variable-length integer (RFC 9000)
    # Returns [value, bytes_consumed]
    def self.decode_varint(bytes, offset = 0)
      first = bytes[offset]
      case (first & 0xC0) >> 6
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

