# frozen_string_literal: true

module Quicsilver
  class Server
    class RequestHandler
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      attr_reader :adapter

      def initialize(app:, configuration:, request_registry:, cancelled_streams:, cancelled_mutex:)
        @configuration = configuration
        @request_registry = request_registry
        @cancelled_streams = cancelled_streams
        @cancelled_mutex = cancelled_mutex
        @adapter = Protocol::Adapter.new(app)
      end

      def call(connection, stream, early_data: false)
        request = parse_request(connection, stream, early_data: early_data)
        return unless request

        response = @adapter.call(request)

        send_response(connection, stream, request, response)
      rescue Server::DrainTimeoutError
        Quicsilver.logger.debug("Request interrupted by drain: stream #{stream.stream_id}")
      rescue Protocol::FrameError => e
        Quicsilver.logger.error("Frame error: #{e.message} (0x#{e.error_code.to_s(16)})")
        Quicsilver.connection_shutdown(connection.handle, e.error_code, false) rescue nil
      rescue Protocol::MessageError => e
        Quicsilver.logger.error("Message error: #{e.message} (0x#{e.error_code.to_s(16)})")
        Quicsilver.stream_reset(stream.stream_handle, e.error_code) if stream.writable?
      rescue => e
        Quicsilver.logger.error("Error handling request: #{e.class} - #{e.message}")
        Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
        connection.send_error(stream, 500, "Internal Server Error") if stream.writable?
      ensure
        @request_registry.complete(stream.stream_id) if @request_registry.include?(stream.stream_id)
        @cancelled_mutex.synchronize { @cancelled_streams.delete(stream.stream_id) }
      end

      private

      def parse_request(connection, stream, early_data: false)
        parser = Protocol::RequestParser.new(
          stream.data,
          max_body_size: @configuration.max_body_size,
          max_header_size: @configuration.max_header_size,
          max_header_count: @configuration.max_header_count,
          max_frame_payload_size: @configuration.max_frame_payload_size
        )
        parser.parse
        parser.validate_headers!

        headers = parser.headers
        unless headers && !headers.empty?
          connection.send_error(stream, 400, "Bad Request") if stream.writable?
          return
        end

        method = headers[":method"]

        if @configuration.early_data_policy == :reject &&
           early_data && !SAFE_METHODS.include?(method)
          connection.send_error(stream, 425, "Too Early") if stream.writable?
          return
        end

        request, body = @adapter.build_request(headers)
        request.headers.add("quicsilver-early-data", early_data.to_s)

        # Wire interim_response so apps can send 103 Early Hints.
        # Falcon mode: app calls request.send_interim_response(103, headers)
        # Rack mode: bridged to rack.early_hints via EarlyHintsMiddleware
        request.interim_response = ->(status, headers) {
          connection.send_informational(stream, status, headers)
        }

        if body && parser.body && parser.body.size > 0
          parser.body.rewind
          body_data = parser.body.read
          body.write(body_data) unless body_data.empty?
        end
        body&.close_write

        connection.apply_stream_priority(stream, parser.priority)

        @request_registry.track(
          stream.stream_id, connection.handle,
          path: headers[":path"] || "/", method: method || "GET"
        )

        request
      end

      def send_response(connection, stream, request, response)
        if cancelled_stream?(stream.stream_id)
          Quicsilver.logger.debug("Skipping response for cancelled stream #{stream.stream_id}")
          return
        end

        raise "Stream handle not found for stream #{stream.stream_id}" unless stream.writable?

        response_headers = {}
        response.headers&.each { |name, value| response_headers[name] = value }

        # Protocol-rack moves content-length from headers to body.length —
        # re-add it so the HTTP/3 response includes the header.
        if !response_headers.key?("content-length") && response.body&.length
          response_headers["content-length"] = response.body.length.to_s
        end

        body = response.body || []
        connection.send_response(stream, response.status, response_headers, body,
          head_request: request.head?)
        @request_registry.complete(stream.stream_id)
      end

      def cancelled_stream?(stream_id)
        @cancelled_mutex.synchronize { @cancelled_streams.include?(stream_id) }
      end
    end
  end
end
