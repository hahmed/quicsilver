# frozen_string_literal: true

require "test_helper"

class RackContextTest < Minitest::Test
  def test_exposes_transport_capabilities
    session = Object.new
    context = Quicsilver::Rack::Context.new(
      stream_id: 8,
      early_data: true,
      webtransport: session,
      metadata: {"connection" => {"connection_id" => "abcd"}}
    )

    assert_equal 8, context.stream_id
    assert context.early_data?
    assert context.webtransport?
    assert_same session, context.webtransport
    assert_equal({"connection_id" => "abcd"}, context["connection"])
  end

  def test_defaults_to_no_optional_capabilities
    context = Quicsilver::Rack::Context.new

    assert_nil context.stream_id
    refute context.early_data?
    refute context.webtransport?
    assert_nil context.webtransport
    assert_nil context["missing"]
  end
end
