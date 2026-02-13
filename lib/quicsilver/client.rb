# frozen_string_literal: true

require_relative "http3/request_encoder"
require_relative "http3/response_parser"
require_relative "event_loop"
require_relative "request"
require_relative "stream"
require_relative "stream_event"
require "timeout"

module Quicsilver
  class Client
    attr_reader :hostname, :port, :unsecure, :connection_timeout, :request_timeout

    AlreadyConnectedError = Class.new(StandardError)
    NotConnectedError = Class.new(StandardError)
    StreamFailedToOpenError = Class.new(StandardError)

    FINISHED_EVENTS = %w[RECEIVE_FIN RECEIVE STREAM_RESET STOP_SENDING].freeze

    DEFAULT_REQUEST_TIMEOUT = 30  # seconds
    DEFAULT_CONNECTION_TIMEOUT = 5000  # ms

    def initialize(hostname, port = 4433, options = {})
      @hostname = hostname
      @port = port
      @unsecure = options.fetch(:unsecure, true)
      @connection_timeout = options.fetch(:connection_timeout, DEFAULT_CONNECTION_TIMEOUT)
      @request_timeout = options.fetch(:request_timeout, DEFAULT_REQUEST_TIMEOUT)

      @connection_data = nil
      @connected = false
      @connection_start_time = nil

      @response_buffers = {}
      @pending_requests = {}  # handle => Request
      @mutex = Mutex.new
    end

    def connect
      raise AlreadyConnectedError if @connected

      Quicsilver.open_connection
      config = Quicsilver.create_configuration(@unsecure)
      raise ConnectionError, "Failed to create configuration" if config.nil?

      start_connection(config)
      @connected = true
      @connection_start_time = Time.now
      send_control_stream
      Quicsilver.event_loop.start

      self
    rescue => e
      cleanup_failed_connection
      raise e.is_a?(ConnectionError) || e.is_a?(TimeoutError) ? e : ConnectionError.new("Connection failed: #{e.message}")
    ensure
      Quicsilver.close_configuration(config)
    end

    def disconnect
      return unless @connection_data

      @connected = false

      # Fail pending requests
      @mutex.synchronize do
        @pending_requests.each_value { |req| req.fail(0, "Connection closed") }
        @pending_requests.clear
        @response_buffers.clear
      end

      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      @connection_data = nil
    end

    # HTTP methods - block gives you request control, no block returns response directly
    #
    #   # Simple (blocking)
    #   response = client.get("/users")
    #
    #   # With control
    #   client.get("/users") do |req|
    #     req.cancel if should_abort?
    #     req.response
    #   end
    #
    %i[get post patch delete head put].each do |method|
      define_method(method) do |path, headers: {}, body: nil, &block|
        req = build_request(method.to_s.upcase, path, headers: headers, body: body)
        block ? block.call(req) : req.response
      end
    end

    # Build and send request, returns Request object for lifecycle control
    def build_request(method, path, headers: {}, body: nil)
      raise NotConnectedError unless @connected

      stream = open_stream
      raise StreamFailedToOpenError unless stream

      request = Request.new(self, stream)
      @mutex.synchronize { @pending_requests[stream.handle] = request }

      send_to_stream(stream, method, path, headers, body)

      request
    end

    def connected?
      @connected && @connection_data && connection_alive?
    end

    def connection_info
      info = @connection_data ? Quicsilver.connection_status(@connection_data[1]) : {}
      info.merge(hostname: @hostname, port: @port, uptime: connection_uptime)
    end

    def connection_uptime
      return 0 unless @connection_start_time
      Time.now - @connection_start_time
    end

    def authority
      "#{@hostname}:#{@port}"
    end

    # Called directly by C extension via dispatch_to_ruby
    def handle_stream_event(stream_id, event, data) # :nodoc:
      return unless FINISHED_EVENTS.include?(event)

      @mutex.synchronize do
        case event
        when "RECEIVE"
          (@response_buffers[stream_id] ||= StringIO.new("".b)).write(data)

        when "RECEIVE_FIN"
          event = StreamEvent.new(data, "RECEIVE_FIN")

          buffer = @response_buffers.delete(stream_id)
          full_data = (buffer&.string || "".b) + event.data

          response_parser = HTTP3::ResponseParser.new(full_data)
          response_parser.parse

          response = {
            status: response_parser.status,
            headers: response_parser.headers,
            body: response_parser.body.read
          }

          request = @pending_requests.delete(event.handle)
          request&.complete(response)

        when "STREAM_RESET"
          event = StreamEvent.new(data, "STREAM_RESET")
          request = @pending_requests.delete(event.handle)
          request&.fail(event.error_code, "Stream reset by peer")

        when "STOP_SENDING"
          event = StreamEvent.new(data, "STOP_SENDING")
          request = @pending_requests.delete(event.handle)
          request&.fail(event.error_code, "Peer sent STOP_SENDING")
        end
      end
    rescue => e
      Quicsilver.logger.error("Error handling client stream: #{e.class} - #{e.message}")
      Quicsilver.logger.debug(e.backtrace.first(5).join("\n"))
    end

    private

    def start_connection(config)
      connection_handle, context_handle = create_connection
      unless Quicsilver.start_connection(connection_handle, config, @hostname, @port)
        cleanup_failed_connection
        raise ConnectionError, "Failed to start connection"
      end

      result = Quicsilver.wait_for_connection(context_handle, @connection_timeout)
      handle_connection_result(result)
    end

    def create_connection
      @connection_data = Quicsilver.create_connection(self)
      raise ConnectionError, "Failed to create connection" if @connection_data.nil?

      @connection_data
    end

    def cleanup_failed_connection
      Quicsilver.close_connection_handle(@connection_data) if @connection_data
      @connection_data = nil
      @connected = false
    end

    def open_stream
      handle = Quicsilver.open_stream(@connection_data, false)
      Stream.new(handle)
    end

    def open_unidirectional_stream
      handle = Quicsilver.open_stream(@connection_data, true)
      Stream.new(handle)
    end

    def send_control_stream
      @control_stream = open_unidirectional_stream
      @control_stream.send(HTTP3.build_control_stream)
    end

    def handle_connection_result(result)
      if result.key?("error")
        cleanup_failed_connection
        raise ConnectionError, "Connection failed: status 0x#{result['status'].to_s(16)}, code: #{result['code']}"
      elsif result.key?("timeout")
        cleanup_failed_connection
        raise TimeoutError, "Connection timed out after #{@connection_timeout}ms"
      end
    end

    def connection_alive?
      return false unless (info = Quicsilver.connection_status(@connection_data[1]))
      info["connected"] && !info["failed"]
    rescue
      false
    end

    def send_to_stream(stream, method, path, headers, body)
      encoded_response = HTTP3::RequestEncoder.new(
        method: method,
        path: path,
        scheme: "https",
        authority: authority,
        headers: headers,
        body: body
      ).encode

      result = stream.send(encoded_response, fin: true)

      unless result
        @mutex.synchronize { @pending_requests.delete(stream.handle) }
        raise Error, "Failed to send request"
      end
    end
  end
end
