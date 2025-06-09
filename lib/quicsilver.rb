# frozen_string_literal: true

require "quicsilver/version"
require "quicsilver.bundle"

module Quicsilver
  class Error < StandardError; end

  # class API
  #   def self.open
  #     # Debug output
  #     puts "Available methods: #{Quicsilver::API.methods - Object.methods}"
      
  #     # Call the C extension method directly
  #     handle = Quicsilver::API.open
  #     # Convert handle to appropriate Ruby object
  #     handle
  #   end
    
  #   def self.close
  #     # Call the C extension method directly
  #     Quicsilver::API.close
  #   end
  # end
end