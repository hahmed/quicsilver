# frozen_string_literal: true

module Quicsilver
  module Transport
    class Connection
      include Protocol::ControlStreamParser

      # MsQuic QUIC_STATUS_INVALID_STATE (POSIX errno ETOOMANYREFS = 0x59).
      # Stream already shut down by peer — raised by StreamSend when the
      # client has reset or closed the stream.
      MSQUIC_INVALID_STATE = "0x59"

      attr_reader :handle, :data, :streams
      attr_reader :control_stream_id, :qpack_encoder_stream_id, :qpack_decoder_stream_id
      attr_reader :server_control_stream
      attr_reader :peer_goaway_id, :local_goaway_id
      attr_reader :stream_priorities
      attr_reader :remote_address, :remote_port, :session_resumed
      def initialize(handle, data, max_header_size: nil, connection_id: nil, cibir_id: nil)
        @handle = handle
        @data = data
        @max_header_size = max_header_size
        @connection_id = hex_string(connection_id)
        @cibir_id = hex_string(cibir_id)
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
        @local_goaway_id = nil
        @stream_priorities = {}
        @session_resumed = @data[2] == true
        @remote_address = nil
        @remote_port = 0
      end

      # Resolve peer address from MsQuic. Must be called before the connection closes.
      def resolve_remote_address!
        result = Quicsilver.connection_remote_address(@handle)
        @remote_address = result&.first
        @remote_port = result&.last&.to_i || 0
      end

      # QUIC original destination connection ID observed by MsQuic.
      attr_reader :connection_id

      # CIBIR (Connection ID Based Implicit Routing) bytes if MsQuic exposes
      # them for the connection. Quicsilver does not assign application meaning
      # to these bytes.
      attr_reader :cibir_id

      def active_streams
        @streams.size
      end

      # HTTP/3 request streams are client-initiated bidirectional QUIC streams.
      def active_request_streams
        @streams.keys.count { |stream_id| StreamId.request?(stream_id) }
      end

      def request_context(stream_id: nil)
        connection = connection_metadata
        connection["stream_id"] = stream_id if stream_id

        {
          "connection" => connection
        }
      end

      def to_h
        connection_metadata.merge(
          "remote_address" => @remote_address,
          "remote_port" => @remote_port,
          "session_resumed" => @session_resumed,
          "streams" => {
            "active" => active_streams,
            "active_requests" => active_request_streams
          },
          "transport" => stats.to_h
        )
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

        # GREASE unidirectional stream (RFC 9114 §6.2)
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
          (@response_buffers[stream_id] ||= "".b) << data
        end
      end

      def complete_stream(stream_id, final_data)
        @mutex.synchronize do
          buffer = @response_buffers.delete(stream_id)
          (buffer || "".b) + (final_data || "".b)
        end
      end

      # === HTTP/3 Frames ===

      def send_goaway(stream_id = nil)
        return unless @server_control_stream

        stream_id ||= last_request_stream_id
        validate_goaway_id!(stream_id)

        @server_control_stream.send(Protocol.build_goaway_frame(stream_id))
        @local_goaway_id = stream_id
      rescue ArgumentError
        raise  # Re-raise validation errors
      rescue => e
        Quicsilver.logger.error("Failed to send GOAWAY: #{e.message}")
      end

      # RFC 9114 §5.2: GOAWAY IDs MUST NOT increase from a previous value.
      def validate_goaway_id!(stream_id)
        if @local_goaway_id && stream_id > @local_goaway_id
          raise ArgumentError, "GOAWAY stream ID #{stream_id} exceeds previous #{@local_goaway_id}"
        end
      end

      # Send an informational (1xx) response before the final response.
      # RFC 9114 §4.1: encoded as a HEADERS frame, no FIN.
      def send_informational(stream, status, headers)
        data = Protocol::ResponseEncoder.encode_informational(status, headers)
        stream.send(data, fin: false)
      rescue RuntimeError => e
        raise unless stream_send_error?(e)
      end

      def send_response(stream, status, headers, body, head_request: false, trailers: nil)
        body = [] if body.nil?
        encoder = Protocol::ResponseEncoder.new(status, headers, body, head_request: head_request, trailers: trailers)

        if body.respond_to?(:to_ary)
          stream.send(encoder.encode, fin: true)
        else
          encoder.stream_encode do |frame_data, fin|
            stream.send(frame_data, fin: fin) unless frame_data.empty? && !fin
          end
        end
      rescue RuntimeError => e
        raise unless stream_send_error?(e)
      ensure
        # RFC 9110: Always close the body to release resources (file handles, fibers, etc.)
        body.close if body.respond_to?(:close)
      end

      def send_error(stream, status, message)
        body = ["#{status} #{message}"]
        headers = { "content-type" => "text/plain" }
        # RFC 9110 §15.6.4: 503 responses SHOULD include Retry-After
        headers["retry-after"] = "1" if status == 503
        encoder = Protocol::ResponseEncoder.new(status, headers, body)
        stream.send(encoder.encode, fin: true)
      rescue RuntimeError => e
        raise unless stream_send_error?(e)
      end

      # === Control Stream Handling ===

      # Process incoming data on a unidirectional stream incrementally.
      # Called on each RECEIVE event — control streams never send FIN.
      def receive_unidirectional_data(stream_id, data)
        @mutex.synchronize do
          (@response_buffers[stream_id] ||= "".b) << data
        end

        buf = @mutex.synchronize { @response_buffers[stream_id] || "".b }
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
            @mutex.synchronize { @response_buffers[stream_id] = (buf[type_len..] || "".b) }
          when 0x01
            raise Protocol::FrameError.new("Client must not send push streams",
              error_code: Protocol::H3_STREAM_CREATION_ERROR)
          when 0x02 # QPACK encoder stream
            raise Protocol::FrameError, "Duplicate QPACK encoder stream" if @qpack_encoder_stream_id
            @qpack_encoder_stream_id = stream_id
            @uni_stream_types[stream_id] = :qpack_encoder
            @mutex.synchronize { @response_buffers[stream_id] = (buf[type_len..] || "".b) }
          when 0x03 # QPACK decoder stream
            raise Protocol::FrameError, "Duplicate QPACK decoder stream" if @qpack_decoder_stream_id
            @qpack_decoder_stream_id = stream_id
            @uni_stream_types[stream_id] = :qpack_decoder
            @mutex.synchronize { @response_buffers[stream_id] = (buf[type_len..] || "".b) }
          when 0x54 # WebTransport unidirectional stream
            @uni_stream_types[stream_id] = :webtransport_uni
            @mutex.synchronize { @response_buffers[stream_id] = (buf[type_len..] || "".b) }
          else
            # Unknown unidirectional stream types MUST be ignored (RFC 9114 §6.2)
            @uni_stream_types[stream_id] = :unknown
            return
          end

          buf = @mutex.synchronize { @response_buffers[stream_id] || "".b }
        end

        stream_type = @uni_stream_types[stream_id]
        return if buf.empty?

        case stream_type
        when :control
          parse_control_frames(buf)
          # Clear parsed data from buffer
          @mutex.synchronize { @response_buffers[stream_id] = "".b }
        when :qpack_encoder
          validate_qpack_encoder_data(buf)
          @mutex.synchronize { @response_buffers[stream_id] = "".b }
        when :qpack_decoder
          validate_qpack_decoder_data(buf)
          @mutex.synchronize { @response_buffers[stream_id] = "".b }
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
          raise Protocol::FrameError.new("Client must not send push streams",
            error_code: Protocol::H3_STREAM_CREATION_ERROR)
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

      def uni_stream_type(stream_id)
        @uni_stream_types&.dig(stream_id)
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

      # Returns QUIC transport statistics for this connection.
      def stats
        ConnectionStats.from_hash(Quicsilver.connection_statistics(@handle))
      end

      def open_stream(unidirectional: false)
        handle = Quicsilver.open_stream(@data, unidirectional)
        Stream.new(handle)
      end

      private

      def hex_string(value)
        value.unpack1("H*") if value
      end

      def connection_metadata
        metadata = {}
        metadata["connection_id"] = connection_id if connection_id
        metadata["cibir_id"] = cibir_id if cibir_id
        metadata
      end

      # Stream may have been reset by client — expected during normal operation.
      def stream_send_error?(error)
        return false unless error.message.include?(MSQUIC_INVALID_STATE) || error.message.include?("StreamSend failed")
        Quicsilver.logger.debug("Stream send failed (client likely reset): #{error.message}")
        true
      end

      def last_request_stream_id
        @streams.keys.select { |stream_id| StreamId.request?(stream_id) }.max || 0
      end

      # Frame types forbidden on the control stream (RFC 9114 §7.2.4)
      # Note: CANCEL_PUSH (0x03) and MAX_PUSH_ID (0x0d) ARE allowed on control stream.
      FORBIDDEN_ON_CONTROL = [
        0x00, # DATA — request streams only
        0x01, # HEADERS — request streams only
        0x02, # HTTP/2 PRIORITY (reserved, §7.2.8)
        0x05, # PUSH_PROMISE — request streams only
        0x06, # HTTP/2 PING (reserved, §7.2.8)
        0x08, # HTTP/2 WINDOW_UPDATE (reserved, §7.2.8)
        0x09, # HTTP/2 CONTINUATION (reserved, §7.2.8)
      ].freeze

      def on_settings_received(settings)
        @settings.merge!(settings)
      end

      def handle_control_frame(type, payload)
        if FORBIDDEN_ON_CONTROL.include?(type)
          raise Protocol::FrameError.new(
            "Frame type 0x#{type.to_s(16)} not allowed on control stream",
            error_code: Protocol::H3_FRAME_UNEXPECTED
          )
        end

        case type
        when Protocol::FRAME_PRIORITY_UPDATE
          parse_priority_update(payload)
        when Protocol::FRAME_CANCEL_PUSH, Protocol::FRAME_MAX_PUSH_ID
          # No-op: we don't implement server push (RFC 9114 §7.2.3, §7.2.7).
          # These are valid on the control stream — accept and ignore.
        end
      end

      # RFC 9218 §7: Parse PRIORITY_UPDATE frame.
      # Payload is a stream ID varint followed by a Priority Field Value string.
      def parse_priority_update(payload)
        stream_id, consumed = Protocol.decode_varint(payload.bytes, 0)
        priority_value = payload[consumed..]
        @stream_priorities[stream_id] = Protocol::Priority.parse(priority_value)
      end

      # RFC 9204 §4.1.3: Validate QPACK encoder stream instructions.
      # We advertise QPACK_MAX_TABLE_CAPACITY = 0, so:
      # - Set Dynamic Table Capacity to 0 is valid (RFC 9204 §3.2.2)
      # - Set Dynamic Table Capacity > 0 is an error
      # - Insert With Name Reference (1xxxxxxx) is an error (no table to insert into)
      # - Insert With Literal Name (01xxxxxx) is an error (capacity is 0)
      # - Duplicate (000xxxxx) is an error (table is empty)
      def validate_qpack_encoder_data(data)
        return if data.empty?
        byte = data.bytes[0]

        # Set Dynamic Table Capacity (001xxxxx)
        if (byte & 0xE0) == 0x20
          capacity, _ = Protocol.decode_varint(data.bytes, 0)
          capacity &= 0x1F  # mask off the instruction prefix
          # Setting to 0 is valid; non-zero exceeds our advertised maximum.
          if capacity > 0
            raise Protocol::FrameError.new(
              "Dynamic table capacity exceeds advertised maximum",
              error_code: Protocol::QPACK_ENCODER_STREAM_ERROR
            )
          end
        elsif (byte & 0x80) == 0x80
          # Insert With Name Reference — cannot insert when capacity=0
          raise Protocol::FrameError.new(
            "Insert instruction received but dynamic table capacity is 0",
            error_code: Protocol::QPACK_ENCODER_STREAM_ERROR
          )
        elsif (byte & 0xC0) == 0x40
          # Insert With Literal Name — cannot insert when capacity=0
          raise Protocol::FrameError.new(
            "Insert instruction received but dynamic table capacity is 0",
            error_code: Protocol::QPACK_ENCODER_STREAM_ERROR
          )
        elsif (byte & 0xE0) == 0x00
          # Duplicate — table is empty, nothing to duplicate
          raise Protocol::FrameError.new(
            "Duplicate instruction received but dynamic table is empty",
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
