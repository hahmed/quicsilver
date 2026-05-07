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
        @streaming_requested = false
      end

      # Whether the caller has opted into streaming via streaming_response.
      def streaming_requested?
        @streaming_requested
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
        @streaming_requested = true
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
          when Response
            @status = :completed
            @response = result
          when Hash
            # Error hash from #fail
            @status = :error
            raise ResetError.new(result[:message] || "Stream reset by peer", result[:error_code])
          end
        end

        @response
      end

      # Stream request body in chunks. Only valid when build_request was
      # called with body: :stream.
      #
      #   req = client.build_request('POST', '/upload', body: :stream)
      #   req.stream_body do |writer|
      #     File.open('big.mp4') do |f|
      #       while (chunk = f.read(16_384))
      #         writer.write(chunk)
      #       end
      #     end
      #   end
      #   req.response  # wait for server response
      #
      def stream_body
        writer = BodyWriter.new(@stream)
        yield writer
        writer.finish
      end

      # Reprioritise this stream (RFC 9218). Sends PRIORITY_UPDATE on the
      # control stream. Can be called while the response is in flight.
      #
      #   req = client.build_request("GET", "/video", priority: Priority.new(urgency: 2))
      #   req.update_priority(Priority.new(urgency: 6))  # deprioritise
      #
      def update_priority(priority)
        @client.send_priority_update(@stream.stream_id, priority)
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

      # Writes request body DATA frames to a QUIC stream.
      class BodyWriter
        def initialize(stream)
          @stream = stream
          @finished = false
        end

        # Write a chunk as an HTTP/3 DATA frame.
        def write(chunk)
          raise "Body already finished" if @finished
          payload = chunk.b
          data = Protocol.encode_varint(Protocol::FRAME_DATA) +
                 Protocol.encode_varint(payload.bytesize) +
                 payload
          @stream.send(data, fin: false)
        end

        # Send FIN to close the request body. Called automatically
        # at the end of stream_body.
        def finish
          return if @finished
          @finished = true
          @stream.send("".b, fin: true)
        end
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
