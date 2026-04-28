# frozen_string_literal: true

require "test_helper"

class ConnectionStatsTest < Minitest::Test
  def test_connection_statistics_c_method_exists
    assert Quicsilver.respond_to?(:connection_statistics)
  end

  def test_client_stats_returns_nil_when_not_connected
    client = Quicsilver::Client.new("localhost", 4433)
    assert_nil client.stats
  end

  def test_server_connection_has_stats_method
    assert Quicsilver::Transport::Connection.method_defined?(:stats)
  end

  def test_connection_stats_from_hash
    hash = {
      "rtt" => 1234, "min_rtt" => 100, "max_rtt" => 5000,
      "resumption_attempted" => false, "resumption_succeeded" => false,
      "send_path_mtu" => 1200,
      "send_total_packets" => 100, "send_retransmittable_packets" => 80,
      "send_suspected_lost_packets" => 5, "send_spurious_lost_packets" => 1,
      "send_total_bytes" => 50000, "send_total_stream_bytes" => 45000,
      "send_congestion_count" => 2, "send_persistent_congestion_count" => 0,
      "send_congestion_window" => 14720,
      "recv_total_packets" => 90, "recv_reordered_packets" => 3,
      "recv_dropped_packets" => 0, "recv_duplicate_packets" => 1,
      "recv_total_bytes" => 60000, "recv_total_stream_bytes" => 55000,
      "recv_decryption_failures" => 0, "recv_valid_ack_frames" => 85,
      "key_update_count" => 0,
    }

    stats = Quicsilver::Transport::ConnectionStats.from_hash(hash)

    assert_equal 1234, stats.rtt
    assert_equal 100, stats.min_rtt
    assert_equal 50000, stats.send_total_bytes
    assert_equal 90, stats.recv_total_packets
    refute stats.resumed?
    assert_in_delta 0.05, stats.packet_loss_rate, 0.001
  end

  def test_connection_stats_from_nil
    assert_nil Quicsilver::Transport::ConnectionStats.from_hash(nil)
  end

  def test_packet_loss_rate_zero_when_no_packets_sent
    hash = {
      "rtt" => 0, "min_rtt" => 0, "max_rtt" => 0,
      "resumption_attempted" => false, "resumption_succeeded" => false,
      "send_path_mtu" => 0,
      "send_total_packets" => 0, "send_retransmittable_packets" => 0,
      "send_suspected_lost_packets" => 0, "send_spurious_lost_packets" => 0,
      "send_total_bytes" => 0, "send_total_stream_bytes" => 0,
      "send_congestion_count" => 0, "send_persistent_congestion_count" => 0,
      "send_congestion_window" => 0,
      "recv_total_packets" => 0, "recv_reordered_packets" => 0,
      "recv_dropped_packets" => 0, "recv_duplicate_packets" => 0,
      "recv_total_bytes" => 0, "recv_total_stream_bytes" => 0,
      "recv_decryption_failures" => 0, "recv_valid_ack_frames" => 0,
      "key_update_count" => 0,
    }
    assert_equal 0.0, Quicsilver::Transport::ConnectionStats.from_hash(hash).packet_loss_rate
  end
end
