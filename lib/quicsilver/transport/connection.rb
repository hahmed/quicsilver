# frozen_string_literal: true

module Quicsilver
  module Transport
    class Connection
      attr_reader :handle, :data, :streams
      attr_reader :control_stream_id, :qpack_encoder_stream_id, :qpack_decoder_stream_id
      attr_reader :server_control_stream
      attr_reader :peer_goaway_id
      attr_reader :stream_priorities

      def initialize(handle, data, max_header_size: nil)
        @handle = handle
        @data = data
        @max_header_size = max_header_size
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
        @peer_goaway_id = nil
        @stream_priorities = {}
      end

      # === Setup (called after connection established) ===

      def setup_http3_streams
        # Control stream (required)
        @server_control_stream = open_stream(unidirectional: true)
        @server_control_stream.send(Protocol.build_control_stream(max_field_section_size: @max_header_size))

        # QPACK encoder/decoder streams
        [0x02, 0x03].each do |type|
          stream = open_stream(unidirectional: true)
          stream.send([type].pack("C"))
        end

        # GREASE unidirectional stream (RFC 9297)
        stream = open_stream(unidirectional: true)
        stream.send(Protocol.encode_varint(Protocol.grease_id) + "GREASE".b)
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

      def send_response(stream, status, headers, body, head_request: false)
        body = [] if body.nil?
        encoder = Protocol::ResponseEncoder.new(status, headers, body, head_request: head_request)

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

      # Process incoming data on a unidirectional stream incrementally.
      # Called on each RECEIVE event — control streams never send FIN.
      def receive_unidirectional_data(stream_id, data)
        @mutex.synchronize do
          (@response_buffers[stream_id] ||= StringIO.new("".b)).write(data)
        end

        buf = @mutex.synchronize { @response_buffers[stream_id]&.string || "".b }
        return if buf.empty?

        # First time seeing this stream: identify stream type
        unless @uni_stream_types&.key?(stream_id)
          @uni_stream_types ||= {}
          stream_type, type_len = Protocol.decode_varint(buf.bytes, 0)
          return if type_len == 0  # need more data

          case stream_type
          when 0x00 # Control stream
            raise Protocol::FrameError, "Duplicate control stream" if @control_stream_id
            @control_stream_id = stream_id
            @uni_stream_types[stream_id] = :control
            # Remove the stream type byte from the buffer
            @mutex.synchronize { @response_buffers[stream_id] = StringIO.new(buf[type_len..] || "".b) }
          when 0x01
            raise Protocol::FrameError, "Client must not send push streams"
          when 0x02 # QPACK encoder stream
            raise Protocol::FrameError, "Duplicate QPACK encoder stream" if @qpack_encoder_stream_id
            @qpack_encoder_stream_id = stream_id
            @uni_stream_types[stream_id] = :qpack_encoder
            @mutex.synchronize { @response_buffers[stream_id] = StringIO.new(buf[type_len..] || "".b) }
          when 0x03 # QPACK decoder stream
            raise Protocol::FrameError, "Duplicate QPACK decoder stream" if @qpack_decoder_stream_id
            @qpack_decoder_stream_id = stream_id
            @uni_stream_types[stream_id] = :qpack_decoder
            @mutex.synchronize { @response_buffers[stream_id] = StringIO.new(buf[type_len..] || "".b) }
          else
            # Unknown unidirectional stream types MUST be ignored (RFC 9114 §6.2)
            @uni_stream_types[stream_id] = :unknown
            return
          end

          buf = @mutex.synchronize { @response_buffers[stream_id]&.string || "".b }
        end

        stream_type = @uni_stream_types[stream_id]
        return if buf.empty?

        case stream_type
        when :control
          parse_control_frames(buf)
          # Clear parsed data from buffer
          @mutex.synchronize { @response_buffers[stream_id] = StringIO.new("".b) }
        when :qpack_encoder
          validate_qpack_encoder_data(buf)
          @mutex.synchronize { @response_buffers[stream_id] = StringIO.new("".b) }
        when :qpack_decoder
          validate_qpack_decoder_data(buf)
          @mutex.synchronize { @response_buffers[stream_id] = StringIO.new("".b) }
        end
      end

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

      # Get the priority for a stream. Returns default Priority if not set.
      def stream_priority(stream_id)
        @stream_priorities[stream_id] || Protocol::Priority.new
      end

      # Apply priority to a QUIC stream via MsQuic.
      # MsQuic: 0 = lowest, 0xFFFF = highest.
      # HTTP urgency: 0 = highest, 7 = lowest.
      # Maps urgency into evenly spaced bands across the uint16 range.
      # The priority is queued and applied on the MsQuic event thread.
      def apply_stream_priority(stream, priority)
        handle = stream.respond_to?(:stream_handle) ? stream.stream_handle : nil
        return unless handle
        quic_priority = (7 - priority.urgency) * 0x2000
        Quicsilver.set_stream_priority(handle, quic_priority)
      rescue => e
        Quicsilver.logger.debug("Failed to set stream priority: #{e.message}")
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
        first_frame = !@settings_received

        Protocol::FrameReader.each(data) do |type, payload|
          if first_frame && type != Protocol::FRAME_SETTINGS
            raise Protocol::FrameError.new("First frame on control stream must be SETTINGS", error_code: Protocol::H3_MISSING_SETTINGS)
          end
          first_frame = false

          if FORBIDDEN_ON_CONTROL.include?(type)
            raise Protocol::FrameError, "Frame type 0x#{type.to_s(16)} not allowed on control stream"
          end

          if type == Protocol::FRAME_SETTINGS
            raise Protocol::FrameError, "Duplicate SETTINGS frame on control stream" if @settings_received
            parse_settings(payload)
            @settings_received = true
          elsif type == Protocol::FRAME_GOAWAY
            parse_goaway(payload)
          elsif type == Protocol::FRAME_PRIORITY_UPDATE
            parse_priority_update(payload)
          end
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
      # RFC 9114 §7.2.6: Validate incoming GOAWAY frame.
      # Stream ID must be a client-initiated bidirectional stream ID (divisible by 4)
      # and must not increase from a previous GOAWAY.
      def parse_goaway(payload)
        stream_id, _ = Protocol.decode_varint(payload.bytes, 0)

        # Must be a valid client-initiated bidirectional stream ID (0, 4, 8, ...)
        unless stream_id % 4 == 0
          raise Protocol::FrameError.new(
            "GOAWAY stream ID #{stream_id} is not a client-initiated bidirectional stream ID",
            error_code: Protocol::H3_ID_ERROR
          )
        end

        # Must not increase from previous GOAWAY
        if @peer_goaway_id && stream_id > @peer_goaway_id
          raise Protocol::FrameError.new(
            "GOAWAY stream ID #{stream_id} exceeds previous #{@peer_goaway_id}",
            error_code: Protocol::H3_ID_ERROR
          )
        end

        @peer_goaway_id = stream_id
      end

      # RFC 9218 §7: Parse PRIORITY_UPDATE frame.
      # Payload is a stream ID varint followed by a Priority Field Value string.
      def parse_priority_update(payload)
        stream_id, consumed = Protocol.decode_varint(payload.bytes, 0)
        priority_value = payload[consumed..]
        @stream_priorities[stream_id] = Protocol::Priority.parse(priority_value)
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
