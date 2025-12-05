# frozen_string_literal: true

module Quicsilver
  module HTTP3
    class ResponseEncoder
      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end

      # Buffered encode - returns all frames at once (legacy)
      def encode
        frames = "".b
        frames << encode_headers_frame
        @body.each do |chunk|
          frames << encode_data_frame(chunk) unless chunk.empty?
        end
        @body.close if @body.respond_to?(:close)
        frames
      end

      # Streaming encode - yields frames as they're ready
      def stream_encode
        yield encode_headers_frame, false

        last_chunk = nil
        @body.each do |chunk|
          yield encode_data_frame(last_chunk), false if last_chunk && !last_chunk.empty?
          last_chunk = chunk
        end

        # Send final chunk with FIN=true
        if last_chunk && !last_chunk.empty?
          yield encode_data_frame(last_chunk), true
        else
          yield "".b, true  # Empty frame to signal FIN
        end

        @body.close if @body.respond_to?(:close)
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
        data_bytes = data.to_s.b
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
                when '200' then HTTP3::QPACK_STATUS_200  # 25
                when '404' then HTTP3::QPACK_STATUS_404  # 27
                when '500' then HTTP3::QPACK_STATUS_500  # 71
                when '400' then HTTP3::QPACK_STATUS_400  # 67
                when '100' then 63
                when '204' then 64
                when '304' then 26
                when '403' then 68
                else nil
                end

        if index
          # Indexed field line: 11 (pattern) + T (1=static) + index (prefix integer with N=6)
          encode_indexed_field_with_prefix(index)
        else
          # Literal with name reference - use index 25 (:status 200) for name
          name_ref = [0x40 | 25].pack('C')
          status_bytes = status_str.b
          length = [status_bytes.bytesize].pack('C')
          name_ref + length + status_bytes
        end
      end

      # Encode indexed field line using prefix integer encoding (RFC 7541)
      # Pattern: 11 + T(1 bit) + index as prefix integer with N=6
      def encode_indexed_field_with_prefix(index, prefix_bits: 6, pattern: 0xC0)
        max_prefix = (1 << prefix_bits) - 1  # 2^6 - 1 = 63

        if index < max_prefix
          # Fits in prefix bits
          [pattern | index].pack('C')
        else
          # Needs continuation bytes
          result = [pattern | max_prefix].pack('C')  # First byte: all prefix bits set to 1
          remaining = index - max_prefix

          # Encode remaining value using 7-bit continuation bytes
          while remaining >= 128
            result += [(remaining & 0x7F) | 0x80].pack('C')  # MSB=1 means more bytes
            remaining >>= 7
          end
          result += [remaining].pack('C')  # Last byte: MSB=0

          result
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
        # Pattern 1: Indexed Field Line with prefix integer encoding
        encode_indexed_field_with_prefix(index)
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
