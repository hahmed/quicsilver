$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "quicsilver"

require "minitest/autorun"
require "minitest/focus"

def cert_data_path
  File.expand_path("../data/certificates", __FILE__)
end

def cert_file_path
  File.join(cert_data_path, "server.crt")
end

def key_file_path
  File.join(cert_data_path, "server.key")
end