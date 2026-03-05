# frozen_string_literal: true

module Quicsilver
  module Transport
    class Connection
      attr_reader :handle, :data, :streams
      attr_reader :control_stream_id, :qpack_encoder_stream_id, :qpack_decoder_stream_id
      attr_reader :server_control_stream

      def initialize(handle, data)
        @handle = handle
        @data = data
        @streams = {}
        @response_buffers = {}
        @mutex = Mutex.new

        # Client's control streams (received)
        @control_stream_id = nil
        @qpack_encoder_stream_id = nil
        @qpack_decoder_stream_id = nil

        # Server's control stream (sent)
        @server_control_stream = nil

        @settings = {}
        @settings_received = false
      end

      # === Setup (called after connection established) ===

      def setup_http3_streams
        # Control stream (required)
        @server_control_stream = open_stream(unidirectional: true)
        @server_control_stream.send(Protocol.build_control_stream)

        # QPACK encoder/decoder streams
        [0x02, 0x03].each do |type|
          stream = open_stream(unidirectional: true)
          stream.send([type].pack("C"))
        end
      end

      # === Stream Management ===

      def add_stream(stream)
        @streams[stream.stream_id] = stream
      end

      def get_stream(stream_id)
        @streams[stream_id]
      end

      def remove_stream(stream_id)
        @streams.delete(stream_id)
      end

      def track_client_stream(stream_id)
        @streams[stream_id] = true
      end

      # === Data Handling ===

      def buffer_data(stream_id, data)
        @mutex.synchronize do
          (@response_buffers[stream_id] ||= StringIO.new("".b)).write(data)
        end
      end

      def complete_stream(stream_id, final_data)
        @mutex.synchronize do
          buffer = @response_buffers.delete(stream_id)
          (buffer&.string || "".b) + (final_data || "".b)
        end
      end

      # === HTTP/3 Frames ===

      def send_goaway(stream_id = nil)
        return unless @server_control_stream

        stream_id ||= last_client_stream_id
        @server_control_stream.send(Protocol.build_goaway_frame(stream_id))
      rescue => e
        Quicsilver.logger.error("Failed to send GOAWAY: #{e.message}")
      end

      def send_response(stream, status, headers, body)
        encoder = Protocol::ResponseEncoder.new(status, headers, body)

        if body.respond_to?(:to_ary)
          Quicsilver.send_stream(stream.stream_handle, encoder.encode, true)
        else
          encoder.stream_encode do |frame_data, fin|
            Quicsilver.send_stream(stream.stream_handle, frame_data, fin) unless frame_data.empty? && !fin
          end
        end
      rescue RuntimeError => e
        # Stream may have been reset by client - this is expected
        raise unless e.message.include?("0x59") || e.message.include?("StreamSend failed")
        Quicsilver.logger.debug("Stream send failed (client likely reset): #{e.message}")
      end

      def send_error(stream, status, message)
        body = ["#{status} #{message}"]
        encoder = Protocol::ResponseEncoder.new(status, { "content-type" => "text/plain" }, body)
        Quicsilver.send_stream(stream.stream_handle, encoder.encode, true)
      rescue RuntimeError => e
        # Stream may have been reset by client - this is expected
        raise unless e.message.include?("0x59") || e.message.include?("StreamSend failed")
        Quicsilver.logger.debug("Stream send failed (client likely reset): #{e.message}")
      end

      # === Control Stream Handling ===

      def handle_unidirectional_stream(stream, fin: true)
        stream_id = stream.stream_id

        # Already known as critical stream — closure via FIN is an error
        if fin && critical_stream?(stream_id)
          raise Protocol::FrameError.new("Closure of critical stream", error_code: Protocol::H3_CLOSED_CRITICAL_STREAM)
        end

        data = stream.data
        return if data.empty?

        stream_type, type_len = Protocol.decode_varint(data.bytes, 0)
        return if type_len == 0
        payload = data[type_len..-1]

        case stream_type
        when 0x00
          set_control_stream(stream_id, payload)
          if fin
            raise Protocol::FrameError.new("Closure of critical stream", error_code: Protocol::H3_CLOSED_CRITICAL_STREAM)
          end
        when 0x01
          raise Protocol::FrameError, "Client must not send push streams"
        when 0x02
          raise Protocol::FrameError, "Duplicate QPACK encoder stream" if @qpack_encoder_stream_id
          @qpack_encoder_stream_id = stream_id
          if fin
            raise Protocol::FrameError.new("Closure of critical stream", error_code: Protocol::H3_CLOSED_CRITICAL_STREAM)
          end
        when 0x03
          raise Protocol::FrameError, "Duplicate QPACK decoder stream" if @qpack_decoder_stream_id
          @qpack_decoder_stream_id = stream_id
          if fin
            raise Protocol::FrameError.new("Closure of critical stream", error_code: Protocol::H3_CLOSED_CRITICAL_STREAM)
          end
        end
      end

      def set_control_stream(stream_id, payload = nil)
        raise Protocol::FrameError, "Duplicate control stream" if @control_stream_id
        @control_stream_id = stream_id
        parse_control_frames(payload) if payload && !payload.empty?
      end

      def settings
        @settings
      end

      def critical_stream?(stream_id)
        stream_id == @control_stream_id ||
          stream_id == @qpack_encoder_stream_id ||
          stream_id == @qpack_decoder_stream_id
      end

      # === Shutdown ===

      def shutdown(error_code = 0)
        send_goaway
        Quicsilver.connection_shutdown(@handle, error_code, false)
      end

      private

      def open_stream(unidirectional: false)
        handle = Quicsilver.open_stream(@data, unidirectional)
        Stream.new(handle)
      end

      def last_client_stream_id
        @streams.keys.select { |id| (id & 0x02) == 0 }.max || 0
      end

      # RFC 9114 §7.2.4.1 / §11.2.2: HTTP/2 setting identifiers forbidden in HTTP/3
      # 0x00 = SETTINGS_HEADER_TABLE_SIZE (reserved), 0x02-0x05 = various HTTP/2 settings
      # Note: 0x08 (SETTINGS_ENABLE_CONNECT_PROTOCOL) is valid in HTTP/3 per RFC 9220
      HTTP2_SETTINGS = [0x00, 0x02, 0x03, 0x04, 0x05].freeze

      # Frame types forbidden on the control stream
      FORBIDDEN_ON_CONTROL = [
        0x00, # DATA — request streams only
        0x01, # HEADERS — request streams only
        0x02, # HTTP/2 PRIORITY (reserved)
        0x05, # PUSH_PROMISE — request streams only
        0x06, # HTTP/2 PING (reserved)
        0x08, # HTTP/2 WINDOW_UPDATE (reserved)
        0x09, # HTTP/2 CONTINUATION (reserved)
      ].freeze

      def parse_control_frames(data)
        offset = 0
        first_frame = !@settings_received

        while offset < data.bytesize
          frame_type, type_len = Protocol.decode_varint(data.bytes, offset)
          frame_length, length_len = Protocol.decode_varint(data.bytes, offset + type_len)
          break if type_len == 0 || length_len == 0

          if first_frame && frame_type != Protocol::FRAME_SETTINGS
            raise Protocol::FrameError.new("First frame on control stream must be SETTINGS", error_code: Protocol::H3_MISSING_SETTINGS)
          end
          first_frame = false

          if FORBIDDEN_ON_CONTROL.include?(frame_type)
            raise Protocol::FrameError, "Frame type 0x#{frame_type.to_s(16)} not allowed on control stream"
          end

          if frame_type == Protocol::FRAME_SETTINGS
            raise Protocol::FrameError, "Duplicate SETTINGS frame on control stream" if @settings_received
            parse_settings(data[offset + type_len + length_len, frame_length])
            @settings_received = true
          end

          offset += type_len + length_len + frame_length
        end
      end

      def parse_settings(payload)
        offset = 0
        seen = Set.new
        while offset < payload.bytesize
          id, id_len = Protocol.decode_varint(payload.bytes, offset)
          value, value_len = Protocol.decode_varint(payload.bytes, offset + id_len)
          break if id_len == 0 || value_len == 0

          if HTTP2_SETTINGS.include?(id)
            raise Protocol::FrameError.new("HTTP/2 setting identifier 0x#{id.to_s(16)} not allowed in HTTP/3", error_code: Protocol::H3_SETTINGS_ERROR)
          end

          raise Protocol::FrameError, "Duplicate setting identifier 0x#{id.to_s(16)}" if seen.include?(id)
          seen.add(id)

          @settings[id] = value
          offset += id_len + value_len
        end
      end
      # RFC 9204 §4.1.3: Validate QPACK encoder stream instructions.
      # We advertise QPACK_MAX_TABLE_CAPACITY = 0, so any Set Dynamic Table Capacity
      # instruction with value > 0 is an error.
      def validate_qpack_encoder_data(data)
        return if data.empty?
        byte = data.bytes[0]

        # Set Dynamic Table Capacity (001xxxxx)
        if (byte & 0xE0) == 0x20
          capacity, _ = Protocol.decode_varint(data.bytes, 0)
          capacity &= 0x1F  # mask off the instruction prefix
          # We advertised capacity 0, any non-zero is an error
          raise Protocol::FrameError.new(
            "Dynamic table capacity exceeds advertised maximum",
            error_code: Protocol::QPACK_ENCODER_STREAM_ERROR
          )
        end
      end

      # RFC 9204 §4.4.3: Validate QPACK decoder stream instructions.
      # Insert Count Increment of 0 is a decoder stream error.
      def validate_qpack_decoder_data(data)
        return if data.empty?
        byte = data.bytes[0]

        # Insert Count Increment (00xxxxxx)
        if (byte & 0xC0) == 0x00
          increment, _ = Protocol.decode_varint(data.bytes, 0)
          increment &= 0x3F  # mask off prefix bits
          if increment == 0
            raise Protocol::FrameError.new(
              "Insert Count Increment of 0 on decoder stream",
              error_code: Protocol::QPACK_DECODER_STREAM_ERROR
            )
          end
        end
      end
    end
  end
end
