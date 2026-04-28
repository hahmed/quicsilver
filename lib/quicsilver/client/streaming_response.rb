# frozen_string_literal: true

module Quicsilver
  class Client
    # A streaming HTTP/3 response. Headers are available immediately;
    # body data arrives incrementally via a StreamInput.
    #
    #   streaming = request.streaming_response(timeout: 10)
    #   streaming.status   # => 200
    #   streaming.headers  # => {"content-type" => "video/mp4"}
    #   while (chunk = streaming.body.read)
    #     file.write(chunk)
    #   end
    #
    class StreamingResponse
      attr_reader :status, :headers, :body, :trailers

      def initialize(status:, headers:, body:, trailers: {})
        @status = status
        @headers = headers
        @body = body
        @trailers = trailers
      end
    end
  end
end
