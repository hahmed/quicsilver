# frozen_string_literal: true

module Quicsilver
  class ListenerData
    attr_reader :listener_handle, :context_handle

    def initialize(listener_handle, context_handle)
      @listener_handle = listener_handle  # The MSQUIC listener handle
      @context_handle = context_handle    # The C context pointer
    end
  end
end