# frozen_string_literal: true

module Quicsilver
  module Transport
    # Immutable snapshot of QUIC transport statistics from MsQuic's QUIC_STATISTICS_V2.
    #
    #   stats = client.stats
    #   stats.rtt                    # => 1234 (microseconds)
    #   stats.send_total_packets     # => 42
    #   stats.recv_total_bytes       # => 98765
    #
    ConnectionStats = Data.define(
      # RTT (microseconds)
      :rtt, :min_rtt, :max_rtt,

      # Handshake
      :resumption_attempted, :resumption_succeeded,

      # Send
      :send_path_mtu,
      :send_total_packets, :send_retransmittable_packets,
      :send_suspected_lost_packets, :send_spurious_lost_packets,
      :send_total_bytes, :send_total_stream_bytes,
      :send_congestion_count, :send_persistent_congestion_count,
      :send_congestion_window,

      # Recv
      :recv_total_packets, :recv_reordered_packets,
      :recv_dropped_packets, :recv_duplicate_packets,
      :recv_total_bytes, :recv_total_stream_bytes,
      :recv_decryption_failures, :recv_valid_ack_frames,

      # Misc
      :key_update_count
    ) do
      # Build from the hash returned by the C extension.
      def self.from_hash(hash)
        return nil unless hash

        new(**hash.transform_keys(&:to_sym))
      end

      def resumed?
        resumption_succeeded
      end

      def packet_loss_rate
        return 0.0 if send_total_packets == 0
        send_suspected_lost_packets.to_f / send_total_packets
      end
    end
  end
end
