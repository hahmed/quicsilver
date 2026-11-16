# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "integration_helper"

class ResponseLogIntegrationTest < Minitest::Test
  include IntegrationHelpers

  def setup
    @log = StringIO.new
    @previous_logger = Quicsilver.logger
    Quicsilver.logger = Logger.new(@log, level: Logger::DEBUG)
  end

  def teardown
    stop_server
    Quicsilver.logger = @previous_logger
  end

  def test_logs_status_length_and_time_for_each_response
    start_server(->(env) { [201, { "content-type" => "text/plain" }, ["created"]] })
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    assert_equal 201, client.get("/things").status
    assert_equal 201, client.post("/things", body: "x" * 64).status

    lines = response_lines
    assert_match %r{\AHTTP/3 response stream=\d+ GET /things 201 length=7 duration=\d+\.\dms\z}, lines[0]
    assert_match %r{\AHTTP/3 response stream=\d+ POST /things 201 length=7 duration=\d+\.\dms\z}, lines[1]
  ensure
    client&.disconnect
  end

  def test_logs_an_application_error_as_a_500
    start_server(->(_env) { raise "boom" })
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    client.get("/explodes")

    # The adapter turns the exception into a 500 response, so it is logged as one.
    assert_match %r{\AHTTP/3 response stream=\d+ GET /explodes 500 }, response_lines.first
  ensure
    client&.disconnect
  end

  private

  def response_lines
    # The line is written after the response is handed to MsQuic, which can be after the client
    # already has it.
    deadline = Time.now + 2
    sleep 0.01 until @log.string.include?("HTTP/3 response") || Time.now > deadline
    sleep 0.05
    @log.string.scan(%r{HTTP/3 response [^\n]*})
  end
end
