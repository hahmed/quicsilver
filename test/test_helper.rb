$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "quicsilver"
require "localhost/authority"

require "minitest/autorun"
require "minitest/focus"

def cert_file_path
  Localhost::Authority.fetch.certificate_path
end

def key_file_path
  Localhost::Authority.fetch.key_path
end