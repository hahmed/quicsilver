# frozen_string_literal: true

module Quicsilver
  class Server
    # A reliable bidirectional stream within a WebTransport session.
    #
    # Streams are opened by either the client or server. Data is reliable
    # and ordered — unlike datagrams, nothing is dropped.
    #
    # Usage:
    #   session.on_stream do |stream|
    #     stream.on_data { |data| stream.write("echo: #{data}") }
    #     stream.on_close { cleanup }
    #   end
    #
    #   # Server-initiated:
    #   stream = session.open_stream
    #   stream.write("server push")
    #   stream.close
    #
    class WebTransportStream
      attr_reader :stream_id, :session

      def initialize(session:, stream:, stream_id:, direction: :bidi)
        @session = session
        @stream = stream
        @stream_id = stream_id
        @direction = direction
        @read_open = direction != :send_only
        @write_open = direction != :receive_only
        @data_callback = nil
        @close_callback = nil
        @close_notified = false
      end

      def stream_handle
        @stream.handle if @stream.respond_to?(:handle)
      end

      def replace_stream_handle(handle)
        @stream = Transport::Stream.new(handle)
      end

      def write(data)
        raise "Cannot write to a receive-only stream" if @direction == :receive_only
        return unless @write_open

        @stream.send(data.to_s.b)
      end

      def close
        close_write
        @read_open = false
        notify_close_callback
      end

      def on_data(&block)
        @data_callback = block
      end

      def on_close(&block)
        @close_callback = block
      end

      def open?
        @read_open || @write_open
      end

      # Called by Server when data arrives on this stream. :nodoc:
      def receive_data(data)
        return if data.nil? || data.empty? || !@read_open

        @data_callback&.call(data)
      end

      # Called by Server when the peer has closed its write side. :nodoc:
      def notify_read_close
        @read_open = false
        notify_close_callback
      end

      # Called by Server when the stream is reset or fully closed. :nodoc:
      def notify_close
        @read_open = false
        @write_open = false
        notify_close_callback
      end

      private

      def close_write
        return unless @write_open

        @stream.send("".b, fin: true) rescue nil
        @write_open = false
      end

      def notify_close_callback
        return if @close_notified

        @close_notified = true
        @close_callback&.call
      end
    end
  end
end
