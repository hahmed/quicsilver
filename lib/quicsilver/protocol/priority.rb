# frozen_string_literal: true

module Quicsilver
  module Protocol
    # HTTP Extensible Priorities (RFC 9218).
    #
    # Parses the `priority` header from HTTP requests. Urgency ranges from
    # 0 (highest) to 7 (lowest), defaulting to 3. Incremental indicates
    # whether partial data is useful to the client (e.g. progressive images).
    #
    # Usage:
    #   priority = Priority.parse("u=0, i")
    #   priority.urgency     # => 0
    #   priority.incremental # => true
    #
    #   priority = Priority.parse(nil)  # default
    #   priority.urgency     # => 3
    #   priority.incremental # => false
    class Priority
      DEFAULT_URGENCY = 3
      MIN_URGENCY = 0
      MAX_URGENCY = 7

      attr_reader :urgency, :incremental

      def initialize(urgency: DEFAULT_URGENCY, incremental: false)
        @urgency = urgency.clamp(MIN_URGENCY, MAX_URGENCY)
        @incremental = incremental
      end

      # Parse a priority header value (RFC 9218 §4, Structured Field Values).
      # Returns a Priority with defaults for missing or invalid values.
      def self.parse(value)
        return new unless value && !value.empty?

        urgency = DEFAULT_URGENCY
        incremental = false

        value.split(",").each do |param|
          param = param.strip
          if param.start_with?("u=")
            urgency = param[2..].to_i
          elsif param == "i"
            incremental = true
          elsif param == "i=?0"
            incremental = false
          elsif param == "i=?1"
            incremental = true
          end
        end

        new(urgency: urgency, incremental: incremental)
      end
    end
  end
end
