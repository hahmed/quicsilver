# frozen_string_literal: true

# Shared helper for examples — uses the `localhost` gem to generate
# self-signed TLS certificates so examples work without manual setup.
#
# Usage:
#   require_relative "example_helper"
#   server = Quicsilver::Server.new(4433, app: app, server_configuration: EXAMPLE_TLS_CONFIG)

require "bundler/setup"
require "quicsilver"
require "localhost/authority"

authority = Localhost::Authority.fetch
EXAMPLE_TLS_CONFIG = Quicsilver::Transport::Configuration.new(
  authority.certificate_path,
  authority.key_path
)
