# frozen_string_literal: true

# Proposal: Protocol::HTTP::Response should have first-class trailer support.
#
# Currently, trailers are embedded in Headers via Headers#trailer! but
# Response has no way to access them directly. This forces adapters to
# split headers from trailers manually every time.
#
# This file shows the problem and two solutions.

require "protocol/http/response"
require "protocol/http/headers"

# === The Problem ===
#
# Building a response with trailers today:
headers = Protocol::HTTP::Headers.new
headers.add("content-type", "text/plain")
headers.trailer!
headers.add("x-checksum", "abc123")
headers.add("grpc-status", "0")

response = Protocol::HTTP::Response.new(nil, 200, headers, nil)

# To get trailers, you have to know about Headers internals:
response.headers.trailer? # => true
response.headers.trailer.to_h # => {"x-checksum" => "abc123", "grpc-status" => "0"}
response.headers.header.to_h # => {"content-type" => "text/plain"}

# Every adapter (HTTP/2, HTTP/3) has to do this split.
# Quicsilver's adapter currently does:
#
#   trailers = extract_trailers(response.headers)  # manual split
#   headers_hash = response_headers_hash(response.headers)  # manual split
#   encoder = ResponseEncoder.new(status, headers_hash, body, trailers: trailers)

# === Solution A: Add trailers to Protocol::HTTP::Response ===
#
# class Protocol::HTTP::Response
#   def trailers
#     return {} unless headers.respond_to?(:trailer?) && headers.trailer?
#     headers.trailer.to_h
#   end
#
#   def response_headers
#     headers&.header&.to_h || {}
#   end
# end
#
# Then adapters just call:
#   response.trailers       # => {"x-checksum" => "abc123"}
#   response.response_headers  # => {"content-type" => "text/plain"}

# === Solution B: Quicsilver subclasses (interim) ===
#
# module Quicsilver
#   module Protocol
#     class Response < ::Protocol::HTTP::Response
#       def trailers
#         return {} unless headers.respond_to?(:trailer?) && headers.trailer?
#         headers.trailer.to_h
#       end
#
#       def response_headers
#         headers&.header&.to_h || {}
#       end
#     end
#   end
# end
#
# Precedent: Protocol::Rack::Response already subclasses Protocol::HTTP::Response

# === Why this matters ===
#
# HTTP/3 sends trailers as a separate HEADERS frame after DATA frames.
# gRPC uses trailers for grpc-status/grpc-message on every response.
# Without Response#trailers, every HTTP/2 and HTTP/3 adapter reimplements
# the same header/trailer split logic.
#
# The Headers#trailer! API already exists — this just promotes it to
# the response level where adapters can use it cleanly.
