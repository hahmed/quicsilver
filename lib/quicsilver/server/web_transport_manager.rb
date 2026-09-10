# frozen_string_literal: true

module Quicsilver
  class Server
    # Tracks WebTransport sessions and routes connection-level stream events.
    #
    # WebTransport child streams arrive at the QUIC/HTTP3 connection before they
    # can be associated with a session. The stream prefix carries the session ID,
    # and that prefix can be split across receives. This object owns that
    # cross-session routing state so Server can stay focused on HTTP/3 dispatch.
    #
    # Scoped to a single connection — see WebTransportRegistry.
    class WebTransportManager
      def initialize
        @sessions = {}
        @pending_streams = {}
        @stream_states = {}
        @pending_uni_streams = {}
      end

      def sessions
        @sessions.values
      end

      def register(session)
        session.stream_manager = self
        @sessions[session.stream_id] = session
      end

      def unregister(stream_id)
        @sessions.delete(stream_id)
      end

      def session(stream_id)
        session = @sessions[stream_id]
        return session if session&.routable?

        @sessions.delete(stream_id) if session&.closed?
        nil
      end

      def routable_sessions
        @sessions.each_value.select(&:routable?)
      end

      def open_session
        @sessions.each_value.find(&:open?)
      end

      def active_stream(stream_id)
        @sessions.each_value do |session|
          next unless session.routable?

          stream = session.stream(stream_id)
          return stream if stream
        end
        nil
      end

      def session_for_stream(stream_id)
        @sessions.each_value do |session|
          next unless session.routable?

          return session if session.stream(stream_id)
        end
        nil
      end

      def register_stream(stream_id)
        @stream_states[stream_id] = :accepted
      end

      def known_stream?(stream_id)
        @stream_states.key?(stream_id)
      end

      def rejected_stream?(stream_id)
        @stream_states[stream_id] == :rejected
      end

      def reject_stream(stream_id, stream_handle)
        @pending_streams.delete(stream_id)
        @pending_uni_streams.delete(stream_id)
        @stream_states[stream_id] = :rejected
        Transport::Stream.new(stream_handle).abort(Protocol::WebTransport::BUFFERED_STREAM_REJECTED)
        nil
      end

      def shutdown_stream(stream_id)
        @pending_uni_streams.delete(stream_id)
        @pending_streams.delete(stream_id)
        known = @stream_states.delete(stream_id)
        return !!known unless (session = session_for_stream(stream_id))

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
        session_id, = WebTransportSession.parse_stream_prefix(payload)
        return reject_stream(stream_id, stream_handle) unless session_id && @sessions[session_id]&.accepts_new_streams?

        WebTransportSession.accept_stream(@sessions, stream_id, stream_handle, payload)
      end

      def accept_uni_stream(stream_id, stream_handle, payload, fin: false)
        if (stream = active_stream(stream_id))
          stream.receive_data(payload)
          return stream
        end
        return if known_stream?(stream_id)

        payload = @pending_uni_streams.delete(stream_id).to_s.b + payload
        _, length = Protocol.decode_varint_str(payload, 0)
        if length == 0
          return reject_stream(stream_id, stream_handle) if fin

          @pending_uni_streams[stream_id] = payload
          return
        end
        session_id, initial_data = WebTransportSession.parse_uni_stream_data(payload)
        session = @sessions[session_id]
        return reject_stream(stream_id, stream_handle) unless session&.accepts_new_streams?

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

        _, sid_len = Protocol.decode_varint_str(data, type_len)
        return :incomplete if sid_len == 0

        :matched
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
