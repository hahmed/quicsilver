# frozen_string_literal: true

module Quicsilver
  class Request
    attr_reader :stream_handle, :status

    CancelledError = Class.new(StandardError)

    class ResetError < StandardError
      attr_reader :error_code

      def initialize(message, error_code = nil)
        super(message)
        @error_code = error_code
      end
    end

    def initialize(client, stream_handle)
      @client = client
      @stream_handle = stream_handle
      @status = :pending
      @queue = Queue.new
      @mutex = Mutex.new
      @response = nil
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

    # Cancel the request (sends RESET_STREAM to server)
    # error_code defaults to H3_REQUEST_CANCELLED (0x10c)
    def cancel(error_code: HTTP3::H3_REQUEST_CANCELLED)
      @mutex.synchronize do
        return false unless @status == :pending

        Quicsilver.stream_reset(@stream_handle, error_code)
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

    # Called by Client when response arrives
    def complete(response) # :nodoc:
      @queue.push(response)
    end

    # Called by Client on stream reset from peer or connection close
    def fail(error_code, message = nil) # :nodoc:
      @status = :error
      @queue.push({ error: true, error_code: error_code, message: message })
    end
  end
end
