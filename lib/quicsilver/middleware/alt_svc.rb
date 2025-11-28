# frozen_string_literal: true

module Quicsilver
  module Middleware
    # Adds Alt-Svc header for HTTP/3 discovery
    # This allows browsers to upgrade from HTTP/1.1 or HTTP/2 to HTTP/3
    class AltSvc
      def initialize(app, port: 4433, max_age: 86400)
        @app = app
        @port = port
        @max_age = max_age
      end

      def call(env)
        status, headers, body = @app.call(env)

        # Add Alt-Svc header to advertise HTTP/3 support
        headers['Alt-Svc'] = "h3=\":#{@port}\"; ma=#{@max_age}"

        [status, headers, body]
      end
    end
  end
end
