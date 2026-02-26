# frozen_string_literal: true

require "test_helper"

class ListenerDataTest < Minitest::Test
  def test_initialize_and_defaults
    data = Quicsilver::Server::ListenerData.new(12345, 67890)

    assert_equal 12345, data.listener_handle
    assert_equal 67890, data.context_handle
  end

  def test_handles_nil
    data = Quicsilver::Server::ListenerData.new(nil, nil)
    assert_nil data.listener_handle
    assert_nil data.context_handle
  end
end
