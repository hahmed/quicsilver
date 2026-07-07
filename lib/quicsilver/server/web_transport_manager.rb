# frozen_string_literal: true

module Quicsilver
  class Server
    # Tracks WebTransport sessions and routes connection-level stream events.
    #
    # WebTransport child streams arrive at the QUIC/HTTP3 connection before they
    # can be associated with a session. The stream prefix carries the session ID,
    # and that prefix can be split across receives. This object owns that
    # cross-session routing state so Server can stay focused on HTTP/3 dispatch.
    class WebTransportManager
      def initialize
        @sessions = {}
        @pending_streams = {}
      end

      def register(session)
        @sessions[session.stream_id] = session
      end

      def unregister(stream_id)
        @sessions.delete(stream_id)
      end

      def session(stream_id)
        @sessions[stream_id]
      end

      def sessions_for_connection(connection)
        @sessions.select { |_id, session| session.connection == connection }
      end

      def open_session_for_connection(connection)
        @sessions.each_value.find { |session| session.connection == connection && session.open? }
      end

      def active_stream(stream_id)
        @sessions.each_value do |session|
          stream = session.stream(stream_id)
          return stream if stream
        end
        nil
      end

      def session_for_stream(stream_id)
        @sessions.each_value do |session|
          return session if session.stream(stream_id)
        end
        nil
      end

      def shutdown_stream(stream_id)
        return false unless (session = session_for_stream(stream_id))

        session.remove_stream(stream_id)
        true
      end

      def pending_stream?(stream_id)
        @pending_streams.key?(stream_id)
      end

      def pending_payload(stream_id, stream_handle, payload)
        pending = @pending_streams[stream_id]
        if pending
          pending[:buffer] << payload
          payload = pending[:buffer]
          stream_handle = pending[:handle]
        end

        case bidi_prefix_state(payload)
        when :matched
          @pending_streams.delete(stream_id)
          payload
        when :incomplete
          @pending_streams[stream_id] ||= { handle: stream_handle, buffer: "".b }
          @pending_streams[stream_id][:buffer] << payload unless pending
          nil
        else
          @pending_streams.delete(stream_id)
          nil
        end
      end

      def bidi_stream?(payload)
        bidi_prefix_state(payload) == :matched
      end

      def accept_bidi_stream(stream_id, stream_handle, payload)
        WebTransportSession.accept_stream(@sessions, stream_id, stream_handle, payload)
      end

      def accept_uni_stream(stream_id, stream_handle, payload)
        session_id, initial_data = WebTransportSession.parse_uni_stream_data(payload)
        return unless session_id
        return unless (session = @sessions[session_id])

        stream = session.add_uni_stream(stream_handle, stream_id)
        stream.receive_data(initial_data) if initial_data && !initial_data.empty?
        stream
      end

      def receive_datagram(datagram)
        stream_id, payload = Protocol::Datagram.decode(datagram)
        return false unless (session = @sessions[stream_id])
        return false unless session.open?

        session.receive_datagram(payload)
        true
      rescue
        false
      end

      def build_datagram(session, payload)
        Protocol::Datagram.encode(session.stream_id, payload)
      end

      private

      def bidi_prefix_state(data)
        type, type_len = Protocol.decode_varint_str(data, 0)
        return :incomplete if type_len == 0 && incomplete_varint?(data, 0)
        return :no_match unless type == WebTransportSession::WT_STREAM_BIDI && type_len > 0

        session_id, sid_len = Protocol.decode_varint_str(data, type_len)
        return :incomplete if sid_len == 0 && incomplete_varint?(data, type_len)

        sid_len > 0 && @sessions[session_id]&.open? ? :matched : :no_match
      rescue
        :no_match
      end

      def incomplete_varint?(data, offset)
        first = data.getbyte(offset)
        return false unless first

        length = 1 << ((first & 0xC0) >> 6)
        data.bytesize - offset < length
      end
    end
  end
end
