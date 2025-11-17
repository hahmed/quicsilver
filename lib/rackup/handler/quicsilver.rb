# frozen_string_literal: true

require "quicsilver"
require "rackup/handler"

module Quicsilver
  module RackHandler
    DEFAULT_OPTIONS = {
      Host: "0.0.0.0",
      Port: 4433,
    }

    def self.run(app, **options)
      normalized_options = {
        host: options[:Host] || options[:host] || DEFAULT_OPTIONS[:Host],
        port: (options[:Port] || options[:port] || DEFAULT_OPTIONS[:Port]).to_i,
      }

      config = ::Quicsilver::ServerConfiguration.new(options[:cert_file], options[:key_file])

      server = ::Quicsilver::Server.new(
        normalized_options[:port],
        address: normalized_options[:host],
        app: app,
        server_configuration: config
      )

      yield server if block_given?

      server.start
      server.wait_for_connections
    end

    def self.valid_options
      {
        "Host=HOST" => "Hostname to listen on (default: 0.0.0.0)",
        "Port=PORT" => "Port to listen on (default: 4433)",
        "cert_file=PATH" => "Path to TLS certificate file (required)",
        "key_file=PATH" => "Path to TLS key file (required)"
      }
    end

  end
end

module Rackup
  module Handler
    module Quicsilver
      def self.run(app, **options, &block)
        ::Quicsilver::RackHandler.run(app, **options, &block)
      end

      def self.valid_options
        ::Quicsilver::RackHandler.valid_options
      end
    end
    register :quicsilver, Quicsilver
  end
end
