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
        result = "".b

        case name
        when ':method'
          # Check if exact match in static table
          index = case @method
          when 'GET' then HTTP3::QPACK_METHOD_GET
          when 'POST' then HTTP3::QPACK_METHOD_POST
          when 'PUT' then HTTP3::QPACK_METHOD_PUT
          when 'DELETE' then HTTP3::QPACK_METHOD_DELETE
          when 'CONNECT' then HTTP3::QPACK_METHOD_CONNECT
          when 'HEAD' then HTTP3::QPACK_METHOD_HEAD
          when 'OPTIONS' then HTTP3::QPACK_METHOD_OPTIONS
          else nil
          end

          if index
            # Exact match - use indexed field line (0x80 | index)
            result += [0x80 | index].pack('C')
          else
            # No exact match - use literal with name reference
            result += [0x40 | HTTP3::QPACK_METHOD_GET].pack('C')  # Use any :method index for name
            result += HTTP3.encode_varint(value.bytesize)
            result += value.b
          end

        when ':scheme'
          # Check if exact match
          index = (@scheme == 'https' ? HTTP3::QPACK_SCHEME_HTTPS : HTTP3::QPACK_SCHEME_HTTP)
          # Exact match - use indexed field line
          result += [0x80 | index].pack('C')

        when ':authority', ':path'
          # Name in static table, but value is custom - use literal with name reference
          index = (name == ':authority' ? HTTP3::QPACK_AUTHORITY : HTTP3::QPACK_PATH)
          result += [0x40 | index].pack('C')
          result += HTTP3.encode_varint(value.bytesize)
          result += value.b

        else
          # Fallback to literal name
          return encode_literal_header(name, value)
        end

        result
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
