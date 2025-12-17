# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-12-17

### Added
- Graceful shutdown with GOAWAY frames (RFC 9114 compliant)
- Streaming response support for lazy/chunked bodies
- Flow control settings for backpressure management
- Client HTTP verb helpers: `get`, `post`, `patch`, `delete`, `head`
- Integration test suite
- Benchmarking examples for Rails

### Fixed
- Memory leak: send buffers now freed on SEND_COMPLETE callback
- Segfault in event loop when client_obj was invalid
- Content-Type header handling for Rack compatibility
- String concatenation performance using StringIO

### Changed
- `server.start` now blocks until shutdown (no separate `wait_for_connections` needed)
- Refactored to global event loop architecture
- Simplified server internals with Connection and QuicStream classes
- Replaced debug puts with proper logging

### Limitations
- No server push or trailer support
- No dynamic QPACK table (static table only)
- Client does not reuse connections

## [0.1.0] - 2025-10-28

### Added
- Initial HTTP/3 server implementation using Microsoft MSQUIC
- HTTP/3 client for testing and development
- Rack support
- HTTP/3 frame encoding/decoding (DATA, HEADERS, SETTINGS)
- QPACK header compression (static table support)
- Bidirectional request/response streams
- Request body buffering for large payloads
