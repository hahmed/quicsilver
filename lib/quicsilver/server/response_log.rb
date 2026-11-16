# frozen_string_literal: true

module Quicsilver
  class Server
    # One DEBUG line per request stream when it finishes, the counterpart of the "HTTP/3 request"
    # line: what happened to the response, as far as the transport can tell.
    #
    #   HTTP/3 response stream=916 GET /boards/1 200 length=18322 duration=15.2ms
    #
    # The application's own log says the request completed; this says whether the response then
    # went out, was skipped because the client cancelled, or failed. duration is the time from the
    # handler picking the stream up to the response being handed to MsQuic, not to the last byte
    # being acknowledged. length is the content-length, or "-" for a body of unknown length.
    module ResponseLog
      module_function

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def record(stream_id:, method:, path:, outcome:, started_at:, headers: nil)
        Quicsilver.logger.debug do
          elapsed = ((now - started_at) * 1000).round(1)
          "HTTP/3 response stream=#{stream_id} #{method} #{path} #{outcome} " \
            "length=#{content_length(headers) || "-"} duration=#{elapsed}ms"
        end
      end

      def content_length(headers)
        headers&.find { |name, _| name == "content-length" }&.last
      end
    end
  end
end
