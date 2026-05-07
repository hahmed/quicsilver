# frozen_string_literal: true

module Quicsilver
  # Unified HTTP/3 response object returned by the client.
  #
  # Used for both buffered and streaming responses:
  # - Buffered: body is a String
  # - Streaming: body is a StreamInput (call body.read in a loop)
  #
  #   response = client.get("/users")
  #   response.status   # => 200
  #   response.headers   # => {"content-type" => "application/json"}
  #   response.body      # => '{"users":["alice"]}'
  #   response.trailers  # => {}
  #
  #   # Streaming
  #   req = client.build_request("GET", "/stream")
  #   response = req.streaming_response(timeout: 10)
  #   response.status   # => 200
  #   while (chunk = response.body.read)
  #     process(chunk)
  #   end
  #
  class Response
    attr_reader :status, :headers, :body, :trailers

    def initialize(status:, headers: {}, body: nil, trailers: {})
      @status = status
      @headers = headers
      @body = body
      @trailers = trailers
    end

    def ok? = status == 200
    def success? = status >= 200 && status < 300
    def redirect? = status >= 300 && status < 400
    def client_error? = status >= 400 && status < 500
    def server_error? = status >= 500 && status < 600
  end
end
