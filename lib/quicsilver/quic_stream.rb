# frozen_string_literal: true

module Quicsilver
  class QuicStream
    attr_reader :stream_id, :is_unidirectional, :buffer
    attr_accessor :stream_handle

    def initialize(stream_id, is_unidirectional: nil)
      @stream_id = stream_id
      @is_unidirectional = is_unidirectional.nil? ? !bidirectional? : is_unidirectional
      @buffer = StringIO.new.tap { |io| io.set_encoding(Encoding::ASCII_8BIT) }
      @stream_handle = nil
    end

    def bidirectional?
      (stream_id & 0x02) == 0
    end

    def ready_to_send?
      !stream_handle.nil?
    end

    def append_data(data)
      @buffer.write(data)
    end

    def clear_buffer
      @buffer.truncate(0)
      @buffer.rewind
    end
  end
end
