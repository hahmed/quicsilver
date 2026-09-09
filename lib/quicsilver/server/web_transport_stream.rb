# frozen_string_literal: true

require "protocol/http/body/writable"

module Quicsilver
  class Server
    # A reliable bidirectional stream within a WebTransport session.
    #
    # Streams are opened by either the client or server. Data is reliable
    # and ordered — unlike datagrams, nothing is dropped.
    #
    # Usage:
    #   session.on_stream do |stream|
    #     Thread.new do
    #       while (data = stream.read)
    #         stream.write("echo: #{data}")
    #       end
    #       stream.close_write
    #     end
    #   end
    #
    #   # Server-initiated:
    #   stream = session.open_stream
    #   stream.write("server push")
    #   stream.close
    #
    class WebTransportStream
      class ResetError < Quicsilver::Error
        attr_reader :http_error_code, :application_error_code

        def initialize(http_error_code)
          @http_error_code = http_error_code
          @application_error_code = Protocol::WebTransport.http_to_application_error(http_error_code)
          super("WebTransport stream reset (HTTP/3 code 0x#{http_error_code.to_s(16)})")
        end
      end

      attr_reader :stream_id, :session

      def initialize(session:, stream:, stream_id:, direction: :bidi)
        @session = session
        @stream = stream
        @stream_id = stream_id
        @direction = direction
        @read_open = direction != :send_only
        @write_open = direction != :receive_only
        @input = ::Protocol::HTTP::Body::Writable.new
        @close_callback = nil
        @reset_callback = nil
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

      # Finish sending and discard unread input; use close_write to keep reading.
      def close
        close_write
        @read_open = false
        @input.close
        notify_close_callback
      end

      # One application reader; never call from the transport event loop.
      def read
        raise IOError, "Cannot read from a send-only stream" if @direction == :send_only

        @input.read
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

        abort(Protocol::WebTransport.application_error_to_http(error_code))
      end

      def abort(http_error_code)
        @stream.abort(http_error_code)
        notify_close(error: ResetError.new(http_error_code))
      end

      def open?
        @read_open || @write_open
      end

      # Called by Server when data arrives on this stream. :nodoc:
      def receive_data(data)
        return if data.nil? || data.empty? || !@read_open

        @input.write(data)
      rescue ::Protocol::HTTP::Body::Writable::Closed, ClosedQueueError, ResetError
        # Closing can race the write after the read-open check above.
        raise if @read_open
      end

      # Called by Server when the peer has closed its write side. :nodoc:
      def notify_read_close
        @read_open = false
        @input.close_write
        notify_close_callback
      end

      # Called by Server when the peer resets this stream. :nodoc:
      def notify_reset(http_error_code)
        error = ResetError.new(http_error_code)
        begin
          notify_close(error: error)
        ensure
          @reset_callback&.call(error.application_error_code)
        end
      end

      # Called by Server when the stream is reset or fully closed. :nodoc:
      def notify_close(error: nil)
        @read_open = false
        @write_open = false
        error ? @input.close(error) : @input.close_write
        notify_close_callback
      end

      def close_write
        return unless @write_open

        @stream.send("".b, fin: true) rescue nil
        @write_open = false
      end

      private

      def notify_close_callback
        return if @close_notified

        @close_notified = true
        @close_callback&.call
      end
    end
  end
end
