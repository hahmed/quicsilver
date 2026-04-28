# frozen_string_literal: true

module Quicsilver
  class Client
    class Request
      attr_reader :stream, :status

      CancelledError = Class.new(StandardError)

      class ResetError < StandardError
        attr_reader :error_code

        def initialize(message, error_code = nil)
          super(message)
          @error_code = error_code
        end
      end

      def initialize(client, stream)
        @client = client
        @stream = stream
        @status = :pending
        @queue = Queue.new
        @streaming_queue = Queue.new
        @mutex = Mutex.new
        @response = nil
        @streaming_response = nil
      end

      # Block until streaming response headers arrive.
      # Returns a StreamingResponse with status, headers, and a readable body.
      # Body data arrives incrementally — call body.read in a loop.
      #
      #   streaming = request.streaming_response(timeout: 10)
      #   streaming.status   # => 200
      #   streaming.headers  # => {"content-type" => "video/mp4"}
      #   while (chunk = streaming.body.read)
      #     file.write(chunk)
      #   end
      #
      def streaming_response(timeout: nil)
        timeout ||= @client.request_timeout
        return @streaming_response if @streaming_response

        result = @streaming_queue.pop(timeout: timeout)
        raise Quicsilver::TimeoutError, "Streaming response timeout after #{timeout}s" if result.nil?

        if result.is_a?(Hash) && result[:error]
          raise ResetError.new(result[:message] || "Stream reset", result[:error_code])
        end

        @streaming_response = result
      end

      # Block until response arrives or timeout
      # Returns response hash { status:, headers:, body: }
      # Raises TimeoutError, CancelledError, or ResetError
      def response(timeout: nil)
        timeout ||= @client.request_timeout
        return @response if @status == :completed

        result = @queue.pop(timeout: timeout)

        @mutex.synchronize do
          case result
          when nil
            raise Quicsilver::TimeoutError, "Request timeout after #{timeout}s"
          when Hash
            if result[:error]
              @status = :error
              raise ResetError.new(result[:message] || "Stream reset by peer", result[:error_code])
            else
              @status = :completed
              @response = result
            end
          end
        end

        @response
      end

      # Cancel the request (sends RESET_STREAM + STOP_SENDING to server)
      # error_code defaults to H3_REQUEST_CANCELLED (0x10c)
      def cancel(error_code: Protocol::H3_REQUEST_CANCELLED)
        @mutex.synchronize do
          return false unless @status == :pending

          @stream.reset(error_code)
          @stream.stop_sending(error_code)
          @status = :cancelled
        end
        true
      rescue => e
        Quicsilver.logger.error("Failed to cancel request: #{e.message}")
        false
      end

      def pending?
        @status == :pending
      end

      def completed?
        @status == :completed
      end

      def cancelled?
        @status == :cancelled
      end

      # Called by Client when buffered response arrives
      def complete(response) # :nodoc:
        @queue.push(response)
      end

      # Called by Client when streaming headers are parsed
      def deliver_streaming(streaming_response) # :nodoc:
        @streaming_queue.push(streaming_response)
      end

      # Called by Client on stream reset from peer or connection close
      def fail(error_code, message = nil) # :nodoc:
        @mutex.synchronize do
          return if @status == :cancelled
          @status = :error
        end
        error = { error: true, error_code: error_code, message: message }
        @queue.push(error)
        @streaming_queue.push(error)
      end
    end
  end
end
