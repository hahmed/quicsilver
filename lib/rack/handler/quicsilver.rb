# frozen_string_literal: true

require "quicsilver"
require "rack"

module Quicsilver
  module RackHandler
    DEFAULT_OPTIONS = {
      Host: "0.0.0.0",
      Port: 4433
    }

    def self.run(app, **options)
      # Rackup passes capitalized keys (:Host, :Port), normalize them
      normalized_options = {
        host: options[:Host] || options[:host] || DEFAULT_OPTIONS[:Host],
        port: options[:Port] || options[:port] || DEFAULT_OPTIONS[:Port],
        cert_file: options[:cert_file],
        key_file: options[:key_file]
      }

      config = ::Quicsilver::ServerConfiguration.new(cert_file, key_file)

      server = ::Quicsilver::Server.new(
        normalized_options[:port],
        address: normalized_options[:host],
        app: app,
        server_configuration: config
      )

      yield server if block_given?

      server.start
      puts "* Listening on https://#{normalized_options[:host]}:#{normalized_options[:port]}"

      trap(:INT) { server.stop }
      trap(:TERM) { server.stop }

      server.wait_for_connections
    end

    def self.valid_options
      {
        "Host=HOST" => "Hostname to listen on (default: 0.0.0.0)",
        "Port=PORT" => "Port to listen on (default: 4433)"
      }
    end
  end
end

if Object.const_defined?(:Rackup) && ::Rackup.const_defined?(:Handler)
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
else
  module Rack
    module Handler
      module Quicsilver
        def self.run(app, **options, &block)
          ::Quicsilver::RackHandler.run(app, **options, &block)
        end

        def self.valid_options
          ::Quicsilver::RackHandler.valid_options
        end
      end
    end
  end
end
