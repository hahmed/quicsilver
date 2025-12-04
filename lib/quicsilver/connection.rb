# frozen_string_literal: true

module Quicsilver
  class Connection
    attr_reader :handle, :data, :control_stream_id, :qpack_encoder_stream_id, :qpack_decoder_stream_id
    attr_reader :streams
    attr_accessor :server_control_stream  # Handle for server's outbound control stream (used to send GOAWAY)

    def initialize(handle, data)
      @handle = handle
      @data = data
      @streams = {}
      @control_stream_id = nil
      @qpack_encoder_stream_id = nil
      @qpack_decoder_stream_id = nil
    end

    def set_qpack_encoder_stream(stream_id)
      @qpack_encoder_stream_id = stream_id
    end

    def set_qpack_decoder_stream(stream_id)
      @qpack_decoder_stream_id = stream_id
    end

    def set_control_stream(stream_id)
      @control_stream_id = stream_id
    end

    def add_stream(stream)
      @streams[stream.stream_id] = stream
    end

    def get_stream(stream_id)
      @streams[stream_id]
    end

    def remove_stream(stream_id)
      @streams.delete(stream_id)
    end
  end
end
