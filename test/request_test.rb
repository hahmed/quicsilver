# frozen_string_literal: true

require "test_helper"

class RequestTest < Minitest::Test
  def setup
    @mock_client = Object.new
    def @mock_client.request_timeout; 30; end
    @mock_stream = Quicsilver::Stream.new(12345)
    @request = Quicsilver::Request.new(@mock_client, @mock_stream)
  end

  def test_initial_state_is_pending
    assert @request.pending?
    refute @request.completed?
    refute @request.cancelled?
    assert_equal :pending, @request.status
  end

  def test_stream_accessible
    assert_equal @mock_stream, @request.stream
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
    stub_cancel do
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
    stub_cancel do
      @request.cancel
      result = @request.cancel
      refute result
    end
  end

  def test_cancel_sends_reset_and_stop_sending
    reset_code = nil
    stop_code = nil
    Quicsilver.stub(:stream_reset, ->(handle, code) { reset_code = code; true }) do
      Quicsilver.stub(:stream_stop_sending, ->(handle, code) { stop_code = code; true }) do
        @request.cancel
      end
    end
    assert_equal Quicsilver::HTTP3::H3_REQUEST_CANCELLED, reset_code
    assert_equal Quicsilver::HTTP3::H3_REQUEST_CANCELLED, stop_code
  end

  def test_cancel_accepts_custom_error_code
    reset_code = nil
    stop_code = nil
    Quicsilver.stub(:stream_reset, ->(handle, code) { reset_code = code; true }) do
      Quicsilver.stub(:stream_stop_sending, ->(handle, code) { stop_code = code; true }) do
        @request.cancel(error_code: 0x999)
      end
    end
    assert_equal 0x999, reset_code
    assert_equal 0x999, stop_code
  end

  def test_fail_does_not_clobber_cancel
    stub_cancel do
      @request.cancel
      @request.fail(0x10c, "Stream reset")

      assert @request.cancelled?, "Cancel should win — fail must not overwrite status outside mutex"
    end
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

  private

  def stub_cancel(&block)
    Quicsilver.stub(:stream_reset, true) do
      Quicsilver.stub(:stream_stop_sending, true) do
        block.call
      end
    end
  end
end
