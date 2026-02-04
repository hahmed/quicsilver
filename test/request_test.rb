# frozen_string_literal: true

require "test_helper"

class RequestTest < Minitest::Test
  def setup
    @mock_client = Object.new
    def @mock_client.request_timeout; 30; end
    @stream_handle = 12345
    @request = Quicsilver::Request.new(@mock_client, @stream_handle)
  end

  def test_initial_state_is_pending
    assert @request.pending?
    refute @request.completed?
    refute @request.cancelled?
    assert_equal :pending, @request.status
  end

  def test_stream_handle_accessible
    assert_equal @stream_handle, @request.stream_handle
  end

  def test_complete_delivers_response
    response = { status: 200, headers: {}, body: "OK" }

    thread = Thread.new { @request.response(timeout: 1) }
    sleep 0.01
    @request.complete(response)

    result = thread.value
    assert_equal 200, result[:status]
    assert_equal "OK", result[:body]
    assert @request.completed?
  end

  def test_response_returns_cached_response_on_subsequent_calls
    response = { status: 200, headers: {}, body: "OK" }
    @request.complete(response)

    result1 = @request.response(timeout: 1)
    result2 = @request.response(timeout: 1)

    assert_same result1, result2
  end

  def test_timeout_raises_timeout_error
    assert_raises(Quicsilver::TimeoutError) do
      @request.response(timeout: 0.01)
    end
  end

  def test_fail_raises_reset_error
    thread = Thread.new do
      @request.response(timeout: 1)
    end
    sleep 0.01
    @request.fail(0x10c, "Stream reset")

    error = assert_raises(Quicsilver::Request::ResetError) { thread.value }
    assert_equal 0x10c, error.error_code
    assert_match(/reset/i, error.message)
  end

  def test_cancel_changes_status_to_cancelled
    # Mock the stream_reset call
    Quicsilver.stub(:stream_reset, true) do
      result = @request.cancel
      assert result
      assert @request.cancelled?
      refute @request.pending?
    end
  end

  def test_cancel_returns_false_if_already_completed
    @request.complete({ status: 200, headers: {}, body: "" })
    @request.response(timeout: 1)

    result = @request.cancel
    refute result
    assert @request.completed?
  end

  def test_cancel_returns_false_if_already_cancelled
    Quicsilver.stub(:stream_reset, true) do
      @request.cancel
      result = @request.cancel
      refute result
    end
  end

  def test_cancel_uses_h3_request_cancelled_by_default
    called_with = nil
    Quicsilver.stub(:stream_reset, ->(handle, code) { called_with = code; true }) do
      @request.cancel
    end
    assert_equal Quicsilver::HTTP3::H3_REQUEST_CANCELLED, called_with
  end

  def test_cancel_accepts_custom_error_code
    called_with = nil
    Quicsilver.stub(:stream_reset, ->(handle, code) { called_with = code; true }) do
      @request.cancel(error_code: 0x999)
    end
    assert_equal 0x999, called_with
  end

  # Error classes
  def test_cancelled_error_exists
    assert_equal Quicsilver::Request::CancelledError.superclass, StandardError
  end

  def test_reset_error_has_error_code
    error = Quicsilver::Request::ResetError.new("test", 0x100)
    assert_equal 0x100, error.error_code
    assert_equal "test", error.message
  end
end
