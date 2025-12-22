# frozen_string_literal: true

module Quicsilver
  class Configuration
    attr_accessor :idle_timeout, :max_streams,
                  :qpack_codec,
                  :stream_window_size, :stream_buffer_size, :connection_window_size

    def initialize
      @idle_timeout = 10_000
      @max_streams = 10
      @qpack_codec = HTTP3::StaticQPACKCodec

      # Flow control (advanced)
      @stream_window_size = 65_536
      @stream_buffer_size = 4_096
      @connection_window_size = 16_777_216
    end
  end
end