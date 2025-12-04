# frozen_string_literal: true

module Quicsilver
  class RequestRegistry
    def initialize
      @requests = {}
      @mutex = Mutex.new
    end

    def track(stream_id, connection_handle, path:, method:, started_at: Time.now)
      @mutex.synchronize do
        @requests[stream_id] = {
          connection_handle: connection_handle,
          path: path,
          method: method,
          started_at: started_at
        }
      end
    end

    def complete(stream_id)
      @mutex.synchronize { @requests.delete(stream_id) }
    end

    def active_count
      @mutex.synchronize { @requests.size }
    end

    def active_requests
      @mutex.synchronize { @requests.dup }
    end

    def requests_older_than(seconds)
      cutoff = Time.now - seconds
      @mutex.synchronize do
        @requests.select { |_, r| r[:started_at] < cutoff }
      end
    end

    def empty?
      @mutex.synchronize { @requests.empty? }
    end

    def include?(stream_id)
      @mutex.synchronize { @requests.key?(stream_id) }
    end
  end
end
