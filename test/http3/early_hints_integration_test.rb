# frozen_string_literal: true

require "test_helper"

# Tests that early hints (103) are wired end-to-end through both modes.
# RFC 9114 §4.1: informational responses before the final response.
class EarlyHintsIntegrationTest < Minitest::Test
  # === Falcon mode (protocol-http native) ===

  def test_falcon_mode_app_can_send_interim_response
    sent_frames = []

    app = ->(request) {
      request.send_interim_response(103, ::Protocol::HTTP::Headers.new(
        [["link", '</style.css>; rel=preload']]
      ))
      Protocol::HTTP::Response[200, {"content-type" => "text/html"}, ["<h1>Hello</h1>"]]
    }

    simulate_request(app, sent_frames)

    assert sent_frames.size >= 2, "Should send informational + final response, got #{sent_frames.size}"

    # First send = 103
    parser = Quicsilver::Protocol::ResponseParser.new(sent_frames.first[:data])
    parser.parse
    assert_equal 103, parser.status
    assert_equal '</style.css>; rel=preload', parser.headers["link"]
    assert_equal false, sent_frames.first[:fin], "103 MUST NOT set FIN"
  end

  # === Rack mode ===

  def test_rack_mode_app_gets_early_hints_in_env
    sent_frames = []
    early_hints_called = false

    rack_app = ->(env) {
      if env["rack.early_hints"]
        env["rack.early_hints"].call("link" => '</style.css>; rel=preload')
        early_hints_called = true
      end
      [200, {"content-type" => "text/html"}, ["<h1>Hello</h1>"]]
    }

    wrapped = wrap_rack_app(rack_app)
    simulate_request(wrapped, sent_frames)

    assert early_hints_called, "Rack app should have received rack.early_hints"
    assert sent_frames.size >= 2, "Should send informational + final"

    parser = Quicsilver::Protocol::ResponseParser.new(sent_frames.first[:data])
    parser.parse
    assert_equal 103, parser.status
  end

  def test_rack_mode_works_without_early_hints
    sent_frames = []

    rack_app = ->(env) {
      [200, {"content-type" => "text/plain"}, ["no hints"]]
    }

    wrapped = wrap_rack_app(rack_app)
    simulate_request(wrapped, sent_frames)

    assert sent_frames.size >= 1, "Should send final response"
  end

  private

  # Mirror Server#wrap_app for :rack mode
  def wrap_rack_app(rack_app)
    early_hints_wrapper = ->(env) {
      request = env["protocol.http.request"]
      if request&.respond_to?(:interim_response) && request.interim_response
        env["rack.early_hints"] = ->(headers) {
          request.send_interim_response(103, ::Protocol::HTTP::Headers[headers.map { |k, v| [k, v] }])
        }
      end
      rack_app.call(env)
    }
    Protocol::Rack::Adapter.new(early_hints_wrapper)
  end

  def simulate_request(app, sent_frames)
    request_data = Quicsilver::Protocol::RequestEncoder.new(
      method: "GET", path: "/", scheme: "https", authority: "localhost:4433"
    ).encode

    stream = Quicsilver::Transport::InboundStream.new(4)
    stream.append_data(request_data)
    stream.stream_handle = Object.new

    connection = Quicsilver::Transport::Connection.new(1, [1, 2])

    # Stub both send paths to capture frames
    Quicsilver.stub(:send_stream, ->(handle, data, fin) {
      sent_frames << { handle: handle, data: data, fin: fin }
      true
    }) do
      adapter = Quicsilver::Protocol::Adapter.new(app)
      handler = Quicsilver::Server::RequestHandler.new(
        app: adapter,
        configuration: Quicsilver::Transport::Configuration.new(
          "test/data/certificates/server.crt",
          "test/data/certificates/server.key"
        ),
        request_registry: Quicsilver::Server::RequestRegistry.new,
        cancelled_streams: Set.new,
        cancelled_mutex: Mutex.new
      )
      handler.call(connection, stream)
    end
  end
end
