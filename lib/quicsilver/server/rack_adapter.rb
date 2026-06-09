# frozen_string_literal: true

module Quicsilver
  class Server
    # Subclass of Protocol::Rack's adapter that adds rack.trailers support.
    #
    # Protocol-rack's wrap_headers creates new Protocol::HTTP::Headers,
    # losing any trailer! state. We override call to inject trailers
    # from env["rack.trailers"] after wrap_headers runs.
    #
    # Usage in a Rack app:
    #   env["rack.trailers"] = { "grpc-status" => "0", "grpc-message" => "OK" }
    #
    class RackAdapter < ::Protocol::Rack::Adapter::Rack31
      def call(request)
        env = self.make_environment(request)
        add_transport_context(env, request)

        # Wire rack.early_hints for 103 Early Hints
        if request.respond_to?(:interim_response) && request.interim_response
          env["rack.early_hints"] = ->(hint_headers) {
            request.send_interim_response(103, ::Protocol::HTTP::Headers[hint_headers.map { |k, v| [k, v] }])
          }
        end

        status, headers, body = @app.call(env)

        headers, meta = self.wrap_headers(headers)

        # Inject trailers from rack.trailers into the protocol-http headers
        if (trailers = env["rack.trailers"]) && trailers.is_a?(Hash) && !trailers.empty?
          headers.trailer!
          trailers.each { |k, v| headers.add(k, v) }
        end

        ::Protocol::Rack::Response.wrap(env, status, headers, meta, body, request)
      rescue => error
        self.handle_error(env, status, headers, body, error)
      end

      private

      def add_transport_context(env, request)
        return unless request.respond_to?(:transport_context)
        return unless (context = request.transport_context)

        connection = context["connection"] || {}

        if connection_id = connection["connection_id"]
          env["quicsilver.connection_id"] = connection_id
        end

        if cibir_id = connection["cibir_id"]
          env["quicsilver.cibir_id"] = cibir_id
        end

        if stream_id = connection["stream_id"]
          env["quicsilver.stream_id"] = stream_id.to_s
        end
      end
    end
  end
end
