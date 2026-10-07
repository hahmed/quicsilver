# frozen_string_literal: true

require_relative "integration_helper"

# send_stream hands MsQuic a pointer into a Ruby String's bytes instead of a
# copy, and MsQuic holds that pointer until SEND_COMPLETE fires. If the String
# is collected in between, the bytes on the wire are whatever the allocator
# reused that memory for. The failure mode is a peer rejecting a mangled
# frame ("DATA frame before HEADERS" on the server), not a crash, so it only
# shows under GC pressure and is silent in a normal test run.
#
# A real client and server, with GC forced continuously in a background
# thread, is the only way to pin this. The first zero-copy version passed the
# whole suite and failed this in under 50 requests.
class SendBufferLifetimeTest < Minitest::Test
  include IntegrationHelpers

  REQUESTS = 600

  def setup
    app = ->(env) do
      size = Integer(env["QUERY_STRING"].to_s[/\d+/] || 2)
      [200, { "content-type" => "text/plain" }, ["x" * size]]
    end
    start_server(app)
  end

  def teardown
    stop_server
  end

  def test_sent_bytes_survive_gc_until_send_complete
    client = Quicsilver::Client.new("localhost", @port, request_timeout: 5)
    client.open_connection

    gc_thread = Thread.new do
      Thread.current.name = "gc-stress"
      loop do
        GC.start
        sleep 0.0005
      end
    end

    bad = []
    REQUESTS.times do |i|
      size = (i % 97) + 1
      response = client.get("/?#{size}")
      next if response&.status == 200 && response.body == "x" * size

      bad << [i, response&.status, response&.body&.bytesize]
    end

    assert_empty bad, "#{bad.size}/#{REQUESTS} responses were wrong under GC pressure; first: #{bad.first.inspect}"
  ensure
    gc_thread&.kill
    client&.disconnect
  end
end
