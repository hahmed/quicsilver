# frozen_string_literal: true

module Quicsilver
  module Transport
    class InboundStream
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

      def writable?
        !stream_handle.nil?
      end

      def append_data(data)
        @buffer.write(data)
      end

      def data
        @buffer.string
      end

      def send(data, fin: false)
        return unless writable?
        Quicsilver.send_stream(@stream_handle, data, fin)
      end

      def reset(error_code = Protocol::H3_REQUEST_CANCELLED)
        return unless writable?
        Quicsilver.stream_reset(@stream_handle, error_code)
      end

      def stop_sending(error_code = Protocol::H3_REQUEST_CANCELLED)
        return unless writable?
        Quicsilver.stream_stop_sending(@stream_handle, error_code)
      end
    end
  end
end
