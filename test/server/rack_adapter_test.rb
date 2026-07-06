# frozen_string_literal: true

require "test_helper"

class RackAdapterTest < Minitest::Test
  def test_call_exposes_transport_context_for_request_debugging
    captured_env = nil
    app = ->(env) {
      captured_env = env
      [200, {"content-type" => "text/plain"}, ["ok"]]
    }
    rack_adapter = Quicsilver::Server::RackAdapter.new(app)
    protocol_adapter = Quicsilver::Protocol::Adapter.new(->(_request) {})
    transport_context = {
      "connection" => {
        "connection_id" => "abcd",
        "request_id" => "01020304:abcd:8",
        "stream_id" => 8
      }
    }
    request, = protocol_adapter.build_request(
      {":method" => "GET", ":scheme" => "https", ":authority" => "example.com", ":path" => "/"},
      transport_context: transport_context
    )

    rack_adapter.call(request)

    assert_equal "abcd", captured_env["quicsilver.connection_id"]
    assert_nil captured_env["quicsilver.original_destination_connection_id"]
    assert_nil captured_env["quicsilver.transport_server_id"]
    assert_equal "01020304:abcd:8", captured_env["quicsilver.request_id"]
    assert_equal 8, captured_env["quicsilver.stream_id"]

    context = captured_env["quicsilver.context"]
    assert_kind_of Quicsilver::Rack::Context, context
    assert_equal 8, context.stream_id
    refute context.early_data?
    refute context.webtransport?
    assert_equal transport_context["connection"], context["connection"]
  end

  def test_call_exposes_request_rack_context
    captured_env = nil
    app = ->(env) {
      captured_env = env
      [200, {"content-type" => "text/plain"}, ["ok"]]
    }
    rack_adapter = Quicsilver::Server::RackAdapter.new(app)
    protocol_adapter = Quicsilver::Protocol::Adapter.new(->(_request) {})
    rack_context = Quicsilver::Rack::Context.new(stream_id: 12, early_data: true)
    request, = protocol_adapter.build_request(
      {":method" => "GET", ":scheme" => "https", ":authority" => "example.com", ":path" => "/"},
      rack_context: rack_context
    )

    rack_adapter.call(request)

    assert_same rack_context, captured_env["quicsilver.context"]
    assert_equal 12, captured_env["quicsilver.context"].stream_id
    assert captured_env["quicsilver.context"].early_data?
  end
end
