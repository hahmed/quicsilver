# frozen_string_literal: true

module Quicsilver
  class ListenerData
    attr_reader :listener_handle, :context_handle, :started, :stopped, :failed, :configuration

    def initialize(listener_handle, context_handle)
      @listener_handle = listener_handle  # The MSQUIC listener handle
      @context_handle = context_handle    # The C context pointer
      # NOTE: Fetch this from the context handle, or improve return values from the C extension
      @started = false
      @stopped = false  
      @failed = false
      @configuration = nil
    end

    def started?
      @started
    end

    def stopped?
      @stopped
    end

    def failed?
      @failed
    end
  end
end