# frozen_string_literal: true

require_relative "integration_helper"

# Validate quicsilver against curl's HTTP/3 client (ngtcp2/nghttp3).
# Proves a real-world client can talk to our server end-to-end.
class CurlHttp3IntegrationTest < Minitest::Test
  include IntegrationHelpers

  def setup
    skip "curl without HTTP/3 support" unless curl_http3_available?
  end

  def teardown
    stop_server
  end

  # --- Basic request/response ---

  def test_get_returns_200_with_body
    app = ->(_env) { [200, { "content-type" => "text/plain" }, ["hello from quicsilver"]] }
    start_server(app)

    result = curl(curl_url("/"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "hello from quicsilver", result.stdout
  end

  def test_head_returns_headers_without_body
    app = ->(_env) { [200, { "content-type" => "text/plain", "content-length" => "5" }, ["hello"]] }
    start_server(app)

    result = curl("-I", curl_url("/"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_match(/HTTP\/3 200/, result.stdout)
    assert_match(/content-type: text\/plain/i, result.stdout)
    assert_match(/content-length: 5/i, result.stdout)
  end

  def test_post_with_body
    received_body = nil
    app = ->(env) {
      received_body = env["rack.input"].read
      [200, { "content-type" => "text/plain" }, ["received: #{received_body}"]]
    }
    start_server(app)

    result = curl("-X", "POST", "-d", "hello=world", curl_url("/submit"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "received: hello=world", result.stdout
    assert_equal "hello=world", received_body
  end

  # --- Response headers ---

  def test_custom_response_headers_returned
    app = ->(_env) { [200, { "x-quicsilver-version" => "0.2.0", "x-request-id" => "abc-123" }, ["ok"]] }
    start_server(app)

    result = curl("-D", "-", curl_url("/"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_match(/x-quicsilver-version: 0\.2\.0/i, result.stdout)
    assert_match(/x-request-id: abc-123/i, result.stdout)
  end

  def test_content_type_json_preserved
    body = '{"status":"ok"}'
    app = ->(_env) { [200, { "content-type" => "application/json" }, [body]] }
    start_server(app)

    result = curl(curl_url("/api"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal body, result.stdout
  end

  # --- Status codes ---

  def test_404_response
    app = ->(env) {
      if env["PATH_INFO"] == "/exists"
        [200, {}, ["found"]]
      else
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end
    }
    start_server(app)

    result = curl("-D", "-", curl_url("/nope"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_match(/HTTP\/3 404/, result.stdout)
    assert_includes result.stdout, "not found"
  end

  def test_500_on_app_exception
    app = ->(_env) { raise "boom" }
    start_server(app)

    result = curl("-D", "-", curl_url("/"))

    assert result.success?, "curl should still get a response: #{result.stderr}"
    assert_match(/HTTP\/3 500/, result.stdout)
  end

  # --- Large body ---

  def test_large_response_body
    # 100KB response
    large_body = "x" * 100_000
    app = ->(_env) { [200, { "content-type" => "application/octet-stream" }, [large_body]] }
    start_server(app)

    result = curl(curl_url("/large"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal 100_000, result.stdout.bytesize, "Expected 100KB response body"
  end

  # --- Query strings ---

  def test_query_string_preserved
    received_qs = nil
    app = ->(env) {
      received_qs = env["QUERY_STRING"]
      [200, { "content-type" => "text/plain" }, ["qs=#{received_qs}"]]
    }
    start_server(app)

    result = curl(curl_url("/search?q=ruby&page=2"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "q=ruby&page=2", received_qs
    assert_equal "qs=q=ruby&page=2", result.stdout
  end

  # --- Request headers from curl ---

  def test_request_headers_received
    received_ua = nil
    received_custom = nil
    app = ->(env) {
      received_ua = env["HTTP_USER_AGENT"]
      received_custom = env["HTTP_X_TEST_HEADER"]
      [200, {}, ["ok"]]
    }
    start_server(app)

    result = curl("-H", "X-Test-Header: compliance-test", "-A", "QuicsilverTest/1.0", curl_url("/"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "QuicsilverTest/1.0", received_ua
    assert_equal "compliance-test", received_custom
  end

  # --- Multiple sequential requests (connection reuse) ---

  def test_sequential_requests
    counter = 0
    app = ->(_env) {
      counter += 1
      [200, { "content-type" => "text/plain" }, ["request-#{counter}"]]
    }
    start_server(app)

    # curl reuses the QUIC connection for multiple URLs in one invocation
    result = curl(curl_url("/a"), curl_url("/b"), curl_url("/c"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal 3, counter, "Server should have received 3 requests"
    assert_includes result.stdout, "request-1"
    assert_includes result.stdout, "request-2"
    assert_includes result.stdout, "request-3"
  end

  # --- HTTP method dispatch ---

  def test_put_request
    received_method = nil
    received_body = nil
    app = ->(env) {
      received_method = env["REQUEST_METHOD"]
      received_body = env["rack.input"].read
      [200, {}, ["updated"]]
    }
    start_server(app)

    result = curl("-X", "PUT", "-d", '{"name":"test"}', curl_url("/resource/1"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "PUT", received_method
    assert_equal '{"name":"test"}', received_body
  end

  def test_delete_request
    received_method = nil
    app = ->(env) {
      received_method = env["REQUEST_METHOD"]
      [204, {}, []]
    }
    start_server(app)

    result = curl("-X", "DELETE", "-D", "-", curl_url("/resource/1"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "DELETE", received_method
    assert_match(/HTTP\/3 204/, result.stdout)
  end

  def test_patch_request
    received_method = nil
    app = ->(env) {
      received_method = env["REQUEST_METHOD"]
      [200, {}, ["patched"]]
    }
    start_server(app)

    result = curl("-X", "PATCH", "-d", "partial", curl_url("/resource/1"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "PATCH", received_method
    assert_equal "patched", result.stdout
  end

  # --- Rack env correctness ---

  def test_rack_env_server_protocol
    received_protocol = nil
    app = ->(env) {
      received_protocol = env["SERVER_PROTOCOL"]
      [200, {}, [received_protocol]]
    }
    start_server(app)

    result = curl(curl_url("/"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "HTTP/3", received_protocol
  end

  def test_rack_env_scheme_is_https
    received_scheme = nil
    app = ->(env) {
      received_scheme = env["rack.url_scheme"]
      [200, {}, [received_scheme]]
    }
    start_server(app)

    result = curl(curl_url("/"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "https", received_scheme
  end

  def test_rack_env_path_and_query_split
    received_path = nil
    received_query = nil
    app = ->(env) {
      received_path = env["PATH_INFO"]
      received_query = env["QUERY_STRING"]
      [200, {}, ["#{received_path}?#{received_query}"]]
    }
    start_server(app)

    result = curl(curl_url("/api/users?role=admin&active=true"))

    assert result.success?, "curl failed: #{result.stderr}"
    assert_equal "/api/users", received_path
    assert_equal "role=admin&active=true", received_query
  end
end
