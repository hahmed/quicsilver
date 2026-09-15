# frozen_string_literal: true

require "protocol/http/body/writable"
require_relative "receive_queue"

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

      def self.validate_overflow_code(code)
        unless code.is_a?(Integer) && code.between?(0, 0xffff_ffff)
          raise ArgumentError, "Receive overflow code must be a 32-bit application error code"
        end
      end

      def initialize(session:, stream:, stream_id:, direction: :bidi,
        receive_buffer_bytes: 1_048_576, receive_buffer_chunks: 1024, receive_overflow_code: 0)
        @session = session
        @stream = stream
        @stream_id = stream_id
        @direction = direction
        @read_open = direction != :send_only
        @write_open = direction != :receive_only
        self.class.validate_overflow_code(receive_overflow_code)
        @receive_overflow_error = Protocol::WebTransport.application_error_to_http(receive_overflow_code)
        queue = ReceiveQueue.new(bytes: receive_buffer_bytes, chunks: receive_buffer_chunks)
        @input = ::Protocol::HTTP::Body::Writable.new(queue: queue)
        @close_callback = nil
        @peer_reset_callback = nil
        @peer_stop_sending_callback = nil
        @close_notified = false
      end

      def stream_handle
        @stream.handle if @stream.respond_to?(:handle)
      end

      def notify_start(stream_id)
        @stream_id = stream_id
      end

      def replace_stream_handle(handle)
        @stream = Transport::Stream.new(handle)
      end

      def write(data)
        raise "Cannot write to a receive-only stream" if @direction == :receive_only
        raise IOError, "Stream is closed for writing" unless @write_open

        @stream.send(data.to_s.b)
      end

      # Finish sending and discard unread input; use close_write to keep reading.
      def close
        close_write
      ensure
        discard_input
      end

      # One application reader; never call from the transport event loop.
      def read
        raise IOError, "Cannot read from a send-only stream" if @direction == :send_only

        @input.read
      end

      def on_close(&block)
        @close_callback = block
      end

      # The peer reset its sending side (RESET_STREAM): our read side is now
      # closed and `read` raises ResetError. Writing is unaffected.
      #
      # Yields the application error code, or nil when the peer used a code
      # outside the WebTransport range (draft-16 §4.4 — still a reset, just no
      # application code to report).
      def on_peer_reset(&block)
        @peer_reset_callback = block
      end

      # The peer asked us to stop sending (STOP_SENDING): our write side is now
      # closed and `write` raises IOError. Reading is unaffected.
      #
      # Yields the application error code on the same terms as on_peer_reset.
      def on_peer_stop_sending(&block)
        @peer_stop_sending_callback = block
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
      rescue ReceiveQueue::Full
        # The reader is too far behind. Close our read side and ask the peer to
        # stop; the write side stays open so the app can still say why.
        begin
          @stream.stop_sending(@receive_overflow_error)
        ensure
          close_read(ResetError.new(@receive_overflow_error))
        end
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

      # RESET_STREAM ends our read side; the write side stays open. :nodoc:
      def notify_peer_reset(http_error_code)
        error = ResetError.new(http_error_code)
        begin
          close_read(error)
        ensure
          @peer_reset_callback&.call(error.application_error_code)
        end
      end

      # STOP_SENDING ends our write side; MsQuic answers it, and we keep
      # receiving on the read side. :nodoc:
      def notify_peer_stop_sending(http_error_code)
        @write_open = false
        begin
          notify_close_callback unless open?
        ensure
          @peer_stop_sending_callback&.call(Protocol::WebTransport.http_to_application_error(http_error_code))
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

        @stream.send("".b, fin: true)
        @write_open = false
        notify_close_callback unless open?
      end

      private

      # Close the read half and fail pending reads, leaving the write half as is.
      def close_read(error)
        @read_open = false
        @input.close(error)
        notify_close_callback unless open?
      end

      def discard_input
        @stream.stop_sending(Protocol::WebTransport.application_error_to_http(0)) if @read_open
      ensure
        @read_open = false
        @input.close
        notify_close_callback
      end

      def notify_close_callback
        return if @close_notified

        @close_notified = true
        @close_callback&.call
      end
    end
  end
end
