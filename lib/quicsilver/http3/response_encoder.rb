# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class ResponseEncoder
      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end

      def encode
        frames = "".b

        # HEADERS frame
        frames << encode_headers_frame

        # DATA frame(s)
        @body.each do |chunk|
          frames << encode_data_frame(chunk) unless chunk.empty?
        end

        @body.close if @body.respond_to?(:close)

        frames
      end

      private

      def encode_headers_frame
        payload = encode_qpack_response

        frame_type = HTTP3.encode_varint(HTTP3::FRAME_HEADERS)
        frame_length = HTTP3.encode_varint(payload.bytesize)

        frame_type + frame_length + payload
      end

      def encode_data_frame(data)
        frame_type = HTTP3.encode_varint(HTTP3::FRAME_DATA)
        data_bytes = data.to_s.b  # Force to binary
        frame_length = HTTP3.encode_varint(data_bytes.bytesize)

        frame_type + frame_length + data_bytes
      end

      def encode_qpack_response
        # QPACK prefix: Required Insert Count = 0, Delta Base = 0
        encoded = [0x00, 0x00].pack('C*')

        # :status pseudo-header - use indexed if possible
        encoded += encode_status(@status)

        # Regular headers
        @headers.each do |name, value|
          next if name.start_with?('rack.')  # Skip Rack internals

          name = name.to_s.downcase
          value = value.to_s

          # Try to use indexed encoding for common headers
          index = find_static_index(name, value)
          if index
            # Pattern 1: Indexed Field Line (1Txxxxxx where T=1 for static)
            encoded += encode_indexed_field(index)
          else
            # Check if just the name exists in static table
            name_index = find_static_name_index(name)
            if name_index
              # Pattern 3: Literal with name reference (01NTxxxx)
              encoded += encode_literal_with_name_ref(name_index, value)
            else
              # Pattern 5: Literal with literal name (001NHxxx)
              encoded += encode_literal_with_literal_name(name, value)
            end
          end
        end

        encoded
      end

      private

      def encode_status(status)
        status_str = status.to_s
        # Map common status codes to static table indices
        index = case status_str
                when '200' then HTTP3::QPACK_STATUS_200
                when '404' then HTTP3::QPACK_STATUS_404
                when '500' then HTTP3::QPACK_STATUS_500
                when '400' then HTTP3::QPACK_STATUS_400
                when '100' then 63
                when '204' then 64
                when '304' then 26
                when '403' then 68
                else nil
                end

        if index
          # Indexed field line: 1T (T=1 static) + index (6 bits)
          [0xC0 | index].pack('C')
        else
          # Literal with name reference to :status name (various indices have :status name)
          # Use index 25 (:status 200) as name reference, provide custom value
          # Pattern 3: 01NTxxxx (N=0, T=1 static, index=24 which has :status as name)
          # Note: index 24 has both :status name and 103 value, we want just the name
          # Actually for non-standard status, safer to use index that's name-only
          # But :status entries all have values. Let's encode as literal with name ref
          # to any :status entry (e.g., 25) and provide our custom value
          name_ref = [0x58].pack('C')  # 01 0 1 1000 = Pattern 3, N=0, T=1(static), index=24
          status_bytes = status_str.b
          length = [status_bytes.bytesize].pack('C')
          name_ref + length + status_bytes
        end
      end

      def find_static_index(name, value)
        HTTP3::STATIC_TABLE.each_with_index do |(tbl_name, tbl_value), idx|
          return idx if tbl_name == name && tbl_value == value
        end
        nil
      end

      def find_static_name_index(name)
        HTTP3::STATIC_TABLE.each_with_index do |(tbl_name, _), idx|
          return idx if tbl_name == name
        end
        nil
      end

      def encode_indexed_field(index)
        # Pattern 1: Indexed Field Line
        # 1T (T=1 for static table) + 6-bit index
        [0xC0 | index].pack('C')
      end

      def encode_literal_with_name_ref(name_index, value)
        # Pattern 3: Literal Field Line with Name Reference
        # 01 N T + 4-bit index (N=0, T=1 for static)
        prefix = 0x40 | name_index
        prefix_byte = [prefix].pack('C')
        value_bytes = value.to_s.b
        value_length = HTTP3.encode_varint(value_bytes.bytesize)
        prefix_byte + value_length + value_bytes
      end

      def encode_literal_with_literal_name(name, value)
        # Pattern 5: Literal Field Line with Literal Name
        # 001 N H + 3-bit name length (N=0, H=0 for no Huffman)
        prefix = 0x20 | name.bytesize
        name_bytes = name.to_s.b
        value_bytes = value.to_s.b
        [prefix].pack('C') + name_bytes + HTTP3.encode_varint(value_bytes.bytesize) + value_bytes
      end
    end
  end
end
