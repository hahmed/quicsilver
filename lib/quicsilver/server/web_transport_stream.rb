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
        @reset_callback = nil
        @close_notified = false
        @buffered_data = []
        @data_mutex = Mutex.new
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

      # Data can arrive before a consumer attaches: accept_stream delivers the
      # stream's first bytes on the event loop thread, while the callback is
      # registered by whatever the on_stream handler spawns. Anything buffered
      # in that window is flushed here, in arrival order.
      def on_data(&block)
        buffered = @data_mutex.synchronize do
          @data_callback = block
          @buffered_data.slice!(0..-1)
        end

        buffered.each { |chunk| block.call(chunk) }
      end

      def on_close(&block)
        @close_callback = block
      end

      # The peer reset this stream. Yields the application error code, or nil
      # when the peer used a code outside the WebTransport range (draft-16
      # §4.4 — still a reset, just no application code to report).
      def on_reset(&block)
        @reset_callback = block
      end

      # Reset this stream with an application error code.
      #
      # §4.4: application codes are 32-bit and share the HTTP/3 error space, so
      # they are mapped into the reserved WT_APPLICATION_ERROR range.
      def reset(error_code)
        return unless @write_open || @read_open

        @stream.reset(Protocol::WebTransport.application_error_to_http(error_code)) rescue nil
        notify_close
      end

      def open?
        @read_open || @write_open
      end

      # Called by Server when data arrives on this stream. :nodoc:
      def receive_data(data)
        return if data.nil? || data.empty? || !@read_open

        callback = @data_mutex.synchronize do
          @buffered_data << data unless @data_callback
          @data_callback
        end

        callback&.call(data)
      end

      # Called by Server when the peer has closed its write side. :nodoc:
      def notify_read_close
        @read_open = false
        notify_close_callback
      end

      # Called by Server when the peer resets this stream. :nodoc:
      def notify_reset(http_error_code)
        @reset_callback&.call(Protocol::WebTransport.http_to_application_error(http_error_code))
        notify_close
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
