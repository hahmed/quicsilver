# frozen_string_literal: true

module Quicsilver
  class Server
    class RequestHandler
      # Safe HTTP methods allowed in 0-RTT early data (RFC 9110 §9.2.1)
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      def initialize(app:, configuration:, request_registry:, cancelled_streams:, cancelled_mutex:)
        @app = app
        @configuration = configuration
        @request_registry = request_registry
        @cancelled_streams = cancelled_streams
        @cancelled_mutex = cancelled_mutex
      end

      def call(connection, stream, early_data: false)
        parser = Protocol::RequestParser.new(
          stream.data,
          max_body_size: @configuration.max_body_size,
          max_header_size: @configuration.max_header_size,
          max_header_count: @configuration.max_header_count,
          max_frame_payload_size: @configuration.max_frame_payload_size
        )
        parser.parse
        parser.validate_headers!
        env = parser.to_rack_env

        if env && @app
          env["quicsilver.early_data"] = early_data

          # RFC 8470: reject unsafe methods on 0-RTT unless app opted in
          if @configuration.early_data_policy == :reject &&
             early_data && !SAFE_METHODS.include?(env["REQUEST_METHOD"])
            connection.send_error(stream, 425, "Too Early") if stream.writable?
            return
          end

          @request_registry.track(
            stream.stream_id,
            connection.handle,
            path: env["PATH_INFO"] || "/",
            method: env["REQUEST_METHOD"] || "GET"
          )

          status, headers, body = @app.call(env)

          if cancelled_stream?(stream.stream_id)
            Quicsilver.logger.debug("Skipping response for cancelled stream #{stream.stream_id}")
            return
          end

          raise "Stream handle not found for stream #{stream.stream_id}" unless stream.writable?

          connection.send_response(stream, status, headers, body)
          @request_registry.complete(stream.stream_id)
        else
          connection.send_error(stream, 400, "Bad Request") if stream.writable?
        end
      rescue Server::DrainTimeoutError
        Quicsilver.logger.debug("Request interrupted by drain: stream #{stream.stream_id}")
      rescue => e
        Quicsilver.logger.error("Error handling request: #{e.class} - #{e.message}")
        Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
        connection.send_error(stream, 500, "Internal Server Error") if stream.writable?
      ensure
        @request_registry.complete(stream.stream_id) if @request_registry.include?(stream.stream_id)
        @cancelled_mutex.synchronize { @cancelled_streams.delete(stream.stream_id) }
      end

      private

      def cancelled_stream?(stream_id)
        @cancelled_mutex.synchronize { @cancelled_streams.include?(stream_id) }
      end
    end
  end
end
