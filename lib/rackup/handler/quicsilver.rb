# frozen_string_literal: true

require "rackup/handler"

module Quicsilver
  module RackHandler
    DEFAULT_OPTIONS = {
      Host: "0.0.0.0",
      Port: 4433,
    }

    class << self
      def run(app, **options)
        normalized_options = {
          host: options[:Host] || options[:host] || DEFAULT_OPTIONS[:Host],
          port: (options[:Port] || options[:port] || DEFAULT_OPTIONS[:Port]).to_i,
        }

        cert_file, key_file = certificate_paths(options)
        config = ::Quicsilver::Transport::Configuration.new(cert_file, key_file)

        server = ::Quicsilver::Server.new(
          normalized_options[:port],
          address: normalized_options[:host],
          app: app,
          server_configuration: config
        )

        yield server if block_given?

        server.start
      end

      def valid_options
        {
          "Host=HOST" => "Hostname to listen on (default: 0.0.0.0)",
          "Port=PORT" => "Port to listen on (default: 4433)",
          "cert_file=PATH" => "Path to TLS certificate file (required in production)",
          "key_file=PATH" => "Path to TLS key file (required in production)"
        }
      end

      private

      def certificate_paths(options)
        cert_file = options[:cert_file]
        key_file = options[:key_file]

        if cert_file.nil? && key_file.nil?
          if production?(options)
            raise ArgumentError, "cert_file and key_file are required in production"
          else
            localhost_certificate_paths
          end
        elsif cert_file.nil? || key_file.nil?
          raise ArgumentError, "cert_file and key_file must be provided together"
        else
          [cert_file, key_file]
        end
      end

      def production?(options)
        env = options[:environment] || ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
        env == "production"
      end

      def localhost_certificate_paths
        require "localhost/authority"
        authority = Localhost::Authority.fetch
        cert_file = authority.certificate_path
        key_file = authority.key_path

        Quicsilver.logger.info("Using auto-generated certificates for localhost")
        Quicsilver.logger.info("  Cert: #{cert_file}")
        Quicsilver.logger.info("  Key: #{key_file}")

        [cert_file, key_file]
      end
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
