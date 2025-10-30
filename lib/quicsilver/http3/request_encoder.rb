# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class RequestEncoder
      def initialize(method:, path:, scheme: 'https', authority: 'localhost:4433', headers: {}, body: nil)
        @method = method.upcase
        @path = path
        @scheme = scheme
        @authority = authority
        @headers = headers
        @body = body
      end

      def encode
        frames = []

        # Build HEADERS frame
        headers_payload = encode_headers
        frames << build_frame(HTTP3::FRAME_HEADERS, headers_payload)

        # Build DATA frame if body present
        if @body && !@body.empty?
          body_data = @body.is_a?(String) ? @body : @body.join
          frames << build_frame(HTTP3::FRAME_DATA, body_data)
        end

        frames.join.force_encoding(Encoding::BINARY)
      end

      private

      def build_frame(type, payload)
        frame_type = HTTP3.encode_varint(type)
        frame_length = HTTP3.encode_varint(payload.bytesize)
        frame_type + frame_length + payload
      end

      def encode_headers
        payload = "".b

        # QPACK prefix: Required Insert Count = 0, Delta Base = 0
        payload += "\x00\x00".b

        # Encode pseudo-headers using Indexed Field Line with Post-Base Index
        # Pattern: 0x50 (0101 0000) for :method, :scheme
        # Pattern: 0x40 | index for :authority, :path (literal name, literal value)

        # :method (use literal since GET/POST have specific indices but we want flexibility)
        payload += encode_literal_pseudo_header(':method', @method)

        # :scheme
        payload += encode_literal_pseudo_header(':scheme', @scheme)

        # :authority
        payload += encode_literal_pseudo_header(':authority', @authority)

        # :path
        payload += encode_literal_pseudo_header(':path', @path)

        # Encode regular headers
        @headers.each do |name, value|
          payload += encode_literal_header(name.to_s.downcase, value.to_s)
        end

        payload
      end

      # Literal field line with literal name for pseudo-headers
      # Pattern: 0x50 (indexed name from static table) + value
      def encode_literal_pseudo_header(name, value)
        # For pseudo-headers, use indexed name reference from static table
        # with literal value (pattern: 0101xxxx where xxxx = static table index)
        static_index = case name
        when ':authority' then HTTP3::QPACK_AUTHORITY
        when ':path' then HTTP3::QPACK_PATH
        when ':method' then (@method == 'GET' ? HTTP3::QPACK_METHOD_GET : HTTP3::QPACK_METHOD_POST)
        when ':scheme' then (@scheme == 'http' ? HTTP3::QPACK_SCHEME_HTTP : HTTP3::QPACK_SCHEME_HTTPS)
        else nil
        end

        if static_index
          # Use indexed field line (0x40 | index)
          result = "".b
          result += [0x40 | static_index].pack('C')
          # For non-exact matches, append literal value
          if name == ':authority' || name == ':path'
            result += HTTP3.encode_varint(value.bytesize)
            result += value.to_s.b
          end
          result
        else
          # Fallback to literal name
          encode_literal_header(name, value)
        end
      end

      # Literal field line with literal name
      # Pattern: 0x20 | name_length, name_bytes, value_length, value_bytes
      def encode_literal_header(name, value)
        result = "".b
        # 0x20 = literal with literal name (no indexing)
        name_len = name.bytesize
        result += [0x20 | (name_len & 0x1F)].pack('C')
        result += name.b
        result += HTTP3.encode_varint(value.bytesize)
        result += value.to_s.b
        result
      end
    end
  end
end
