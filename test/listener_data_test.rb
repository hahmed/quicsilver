# frozen_string_literal: true

require "test_helper"
require_relative "../lib/quicsilver/listener_data"

class ListenerDataTest < Minitest::Test
  def test_initialize_and_defaults
    data = Quicsilver::ListenerData.new(12345, 67890)

    assert_equal 12345, data.listener_handle
    assert_equal 67890, data.context_handle
    refute data.started?
    refute data.stopped?
    refute data.failed?
    assert_nil data.configuration
  end

  def test_handles_nil
    data = Quicsilver::ListenerData.new(nil, nil)
    assert_nil data.listener_handle
    assert_nil data.context_handle
  end
end
