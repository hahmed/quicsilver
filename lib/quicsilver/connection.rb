# frozen_string_literal: true

module Quicsilver
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
    end

    # === Setup (called after connection established) ===

    def setup_http3_streams
      # Control stream (required)
      @server_control_stream = open_stream(unidirectional: true)
      @server_control_stream.send(HTTP3.build_control_stream)

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

    # === Data Handling ===

    def buffer_data(stream_id, data)
      @mutex.synchronize do
        (@response_buffers[stream_id] ||= StringIO.new("".b)).write(data)
      end
    end

    def complete_stream(stream_id, final_data)
      @mutex.synchronize do
        buffer = @response_buffers.delete(stream_id)
        (buffer&.string || "") + (final_data || "")
      end
    end

    # === HTTP/3 Frames ===

    def send_goaway(stream_id = nil)
      return unless @server_control_stream

      stream_id ||= last_client_stream_id
      @server_control_stream.send(HTTP3.build_goaway_frame(stream_id))
    rescue => e
      Quicsilver.logger.error("Failed to send GOAWAY: #{e.message}")
    end

    def send_response(stream, status, headers, body)
      encoder = HTTP3::ResponseEncoder.new(status, headers, body)

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
      encoder = HTTP3::ResponseEncoder.new(status, { "content-type" => "text/plain" }, body)
      Quicsilver.send_stream(stream.stream_handle, encoder.encode, true)
    rescue RuntimeError => e
      # Stream may have been reset by client - this is expected
      raise unless e.message.include?("0x59") || e.message.include?("StreamSend failed")
      Quicsilver.logger.debug("Stream send failed (client likely reset): #{e.message}")
    end

    # === Control Stream Handling ===

    def handle_unidirectional_stream(stream)
      data = stream.data
      return if data.empty?

      stream_type = data[0].ord
      payload = data[1..-1]

      case stream_type
      when 0x00 then set_control_stream(stream.stream_id, payload)
      when 0x02 then @qpack_encoder_stream_id = stream.stream_id
      when 0x03 then @qpack_decoder_stream_id = stream.stream_id
      end
    end

    def set_control_stream(stream_id, payload = nil)
      @control_stream_id = stream_id
      parse_control_frames(payload) if payload && !payload.empty?
    end

    def settings
      @settings
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

    def parse_control_frames(data)
      offset = 0
      while offset < data.bytesize
        frame_type, type_len = HTTP3.decode_varint(data.bytes, offset)
        frame_length, length_len = HTTP3.decode_varint(data.bytes, offset + type_len)

        if frame_type == HTTP3::FRAME_SETTINGS
          parse_settings(data[offset + type_len + length_len, frame_length])
        end

        offset += type_len + length_len + frame_length
      end
    end

    def parse_settings(payload)
      offset = 0
      while offset < payload.bytesize
        id, id_len = HTTP3.decode_varint(payload.bytes, offset)
        value, value_len = HTTP3.decode_varint(payload.bytes, offset + id_len)
        @settings[id] = value
        offset += id_len + value_len
      end
    end
  end
end
