# frozen_string_literal: true

module Quicsilver
  module Protocol
    # Shared control stream parsing for both server Connection and Client.
    #
    # RFC 9114 §7.2.4: Both endpoints MUST send and process SETTINGS.
    # RFC 9114 §7.2.6: Both endpoints MUST validate incoming GOAWAY.
    #
    # Includer must provide:
    #   @settings_received — boolean, initially false
    #   @peer_goaway_id   — nil initially
    #
    # Includer may override:
    #   on_settings_received(settings_hash) — called after SETTINGS parsed
    #   on_goaway_received(stream_id)       — called after GOAWAY parsed
    #   handle_control_frame(type, payload) — called for non-SETTINGS/GOAWAY frames
    module ControlStreamParser
      # RFC 9114 §7.2.4.1 / §11.2.2: HTTP/2 setting identifiers forbidden in HTTP/3
      # 0x00 = SETTINGS_HEADER_TABLE_SIZE (reserved), 0x02-0x05 = various HTTP/2 settings
      # Note: 0x08 (SETTINGS_ENABLE_CONNECT_PROTOCOL) is valid in HTTP/3 per RFC 9220
      HTTP2_SETTINGS = [0x00, 0x02, 0x03, 0x04, 0x05].freeze

      def parse_control_frames(data)
        first_frame = !@settings_received

        Protocol::FrameReader.each(data) do |type, payload|
          if first_frame && type != Protocol::FRAME_SETTINGS
            raise Protocol::FrameError.new("First frame on control stream must be SETTINGS",
              error_code: Protocol::H3_MISSING_SETTINGS)
          end
          first_frame = false

          case type
          when Protocol::FRAME_SETTINGS
            raise Protocol::FrameError, "Duplicate SETTINGS frame on control stream" if @settings_received
            parse_peer_settings(payload)
            @settings_received = true
          when Protocol::FRAME_GOAWAY
            parse_peer_goaway(payload)
          else
            handle_control_frame(type, payload)
          end
        end
      end

      def parse_peer_settings(payload)
        offset = 0
        seen = Set.new
        settings = {}

        while offset < payload.bytesize
          id, id_len = Protocol.decode_varint(payload.bytes, offset)
          value, value_len = Protocol.decode_varint(payload.bytes, offset + id_len)
          break if id_len == 0 || value_len == 0

          if HTTP2_SETTINGS.include?(id)
            raise Protocol::FrameError.new("HTTP/2 setting identifier 0x#{id.to_s(16)} not allowed in HTTP/3",
              error_code: Protocol::H3_SETTINGS_ERROR)
          end

          raise Protocol::FrameError, "Duplicate setting identifier 0x#{id.to_s(16)}" if seen.include?(id)
          seen.add(id)

          settings[id] = value
          offset += id_len + value_len
        end

        on_settings_received(settings)
      end

      # RFC 9114 §7.2.6: Validate incoming GOAWAY frame.
      # Stream ID must be a client-initiated bidirectional stream ID (divisible by 4)
      # and must not increase from a previous GOAWAY.
      def parse_peer_goaway(payload)
        stream_id, _ = Protocol.decode_varint(payload.bytes, 0)

        unless stream_id % 4 == 0
          raise Protocol::FrameError.new(
            "GOAWAY stream ID #{stream_id} is not a client-initiated bidirectional stream ID",
            error_code: Protocol::H3_ID_ERROR)
        end

        if @peer_goaway_id && stream_id > @peer_goaway_id
          raise Protocol::FrameError.new(
            "GOAWAY stream ID #{stream_id} exceeds previous #{@peer_goaway_id}",
            error_code: Protocol::H3_ID_ERROR)
        end

        @peer_goaway_id = stream_id
      end

      private

      # Override in includer to store settings. Default: no-op.
      def on_settings_received(settings)
      end

      # Override in includer to handle additional frame types on the control stream.
      # Server handles FORBIDDEN_ON_CONTROL and PRIORITY_UPDATE here.
      # Client ignores unknown frames.
      def handle_control_frame(type, payload)
      end
    end
  end
end
