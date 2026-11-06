# frozen_string_literal: true

require "digest"
require "rbconfig"

module Quicsilver
  # Where a locally built C extension lives, shared by lib/quicsilver.rb and the
  # Rakefile so the build and the require cannot disagree.
  #
  # Keying on the ABI version alone is not enough in a source checkout. Ruby
  # 4.0.7 under nix and 4.0.9 under mise both answer "4.0", but an extension
  # linked against one install's libruby will not load under the other:
  #
  #   linked to incompatible /nix/store/.../libruby.4.0.dylib - quicsilver.bundle
  #
  # The install prefix distinguishes them, so builds from different Rubies
  # coexist instead of overwriting each other. Released gems are unaffected:
  # extconf.rb installs flat, and REQUIRE_PATHS still falls back to that.
  module Extension
    ABI = RUBY_VERSION[/\d+\.\d+/]

    # Short digest of the install prefix. Two Rubies reporting the same version
    # from different prefixes get different directories.
    INSTALL_TAG = Digest::SHA256.hexdigest(RbConfig::CONFIG["prefix"].to_s)[0, 8]

    # Directory a local `rake compile` installs into, relative to lib/quicsilver.
    DIR = "#{ABI}-#{INSTALL_TAG}"

    # Tried in order: this exact Ruby install, then any build for this ABI
    # (older checkouts), then the flat path a released gem ships.
    REQUIRE_PATHS = [
      "quicsilver/#{DIR}/quicsilver",
      "quicsilver/#{ABI}/quicsilver",
      "quicsilver/quicsilver"
    ].freeze
  end
end
