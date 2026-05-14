# frozen_string_literal: true

require "test_helper"

class ClientResumptionTest < Minitest::Test
  def setup
    @app = ->(env) { [200, { "content-type" => "text/plain" }, ["PONG"]] }
    @port = find_available_port
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    @server = Quicsilver::Server.new(@port, app: @app, server_configuration: config)
    @server_thread = Thread.new { @server.start }
    wait_for_server(@server)
  end

  def teardown
    @server&.stop
    @server_thread&.join(2)
  end

  def test_first_connection_is_not_resumed
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.open_connection
    client.get("/")

    stats = client.stats
    refute stats.resumed?, "First connection should not be resumed"
  ensure
    client&.disconnect
  end

  def test_second_connection_is_resumed_via_0rtt
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # First connection — establishes session, receives ticket
    client.open_connection
    client.get("/")
    first_stats = client.stats
    refute first_stats.resumed?, "First connection should not be resumed"
    client.disconnect

    sleep 0.1

    # Second connection — should use the saved resumption ticket
    client.open_connection
    response = client.get("/")
    second_stats = client.stats

    assert_equal 200, response.status
    assert_equal "PONG", response.body
    assert second_stats.resumed?, "Second connection should be resumed (0-RTT)"
  ensure
    client&.disconnect
  end

  def test_resumption_ticket_is_saved_on_disconnect
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client.open_connection
    client.get("/")
    client.disconnect

    ticket = client.instance_variable_get(:@resumption_ticket)
    refute_nil ticket, "Resumption ticket should be saved after disconnect"
    assert_kind_of String, ticket
    refute_empty ticket
  end

  def test_no_ticket_before_first_connection
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    ticket = client.instance_variable_get(:@resumption_ticket)
    assert_nil ticket, "No ticket should exist before first connection"
  end

  def test_multiple_reconnections_all_resume
    client = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # First connection
    client.open_connection
    client.get("/")
    client.disconnect

    3.times do |i|
      sleep 0.1
      client.open_connection
      response = client.get("/")
      stats = client.stats

      assert_equal 200, response.status
      assert stats.resumed?, "Reconnection #{i + 1} should be resumed"
      client.disconnect
    end
  end

  def test_different_clients_do_not_share_tickets
    client1 = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)
    client2 = Quicsilver::Client.new("127.0.0.1", @port, unsecure: true)

    # client1 establishes session
    client1.open_connection
    client1.get("/")
    client1.disconnect

    # client2 is fresh — should NOT be resumed
    client2.open_connection
    client2.get("/")
    stats = client2.stats

    refute stats.resumed?, "Different client instance should not reuse another client's ticket"
  ensure
    client1&.disconnect
    client2&.disconnect
  end
end
