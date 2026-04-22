# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - Unreleased

### Added
- Client connection pool with automatic reuse (`Quicsilver::Client.get/post` class-level API)
- GREASE support (RFC 9297) — settings, frames, and unidirectional streams
- GOAWAY validation (RFC 9114 §7.2.6) — monotonically decreasing IDs, stream ID validation
- Trailer support (RFC 9114 §4.1) — parse and send trailing HEADERS frames
- Extensible Priorities (RFC 9218) — parse `priority` header, PRIORITY_UPDATE frames on control stream, MsQuic stream priority mapping
- FrameParser base class — unified frame walking, ordering, body accumulation, size limits
- FrameReader module — shared byte-level frame extraction for request/response/control streams
- Trailer wiring in Adapter and StreamOutput for protocol-http integration
- MIT license in gemspec

### Fixed
- QPACK prefix decoding — decode Required Insert Count and Delta Base as varints instead of hardcoded `offset = 2`
- Default decoder rejects payloads referencing the dynamic table
- Response parser now enforces `max_frame_payload_size` (was missing)
- Duplicate `frames` method in FrameParser
- Consistent `@headers` and `@trailers` initialization (`{}` not `nil`)
- extconf.rb — force Apple clang on macOS (Homebrew clang produces broken MsQuic binaries)

### Changed
- RequestParser and ResponseParser inherit from FrameParser (reduced ~230 lines of duplication)
- `store_header`, `body`, `DEFAULT_DECODER`, `EMPTY_BODY`, `parse!` moved to FrameParser base class
- `@body_io` renamed to `@body` in ResponseParser for consistency
- ResponseEncoder accepts optional `trailers:` hash
- StreamOutput accepts `send_fin:` parameter for trailer support

## [0.3.0] - 2026-03-23

### Added
- QPACK Huffman coding with 8-bit decode table and encode/decode caching
- 0-RTT replay protection for unsafe HTTP methods
- Bounded backpressure support
- Buffer size limits to prevent memory exhaustion (configurable `max_body_size`, `max_header_size`, `max_header_count`, `max_frame_payload_size`)
- Content-length validation
- Multi-value header support for duplicate header fields
- Headers validation: reject connection-specific headers, require `:authority` or `host` for http/https schemes
- Incremental unidirectional stream processing with critical stream protection
- QPACK encoder and decoder stream instruction validation
- Spec-correct error signaling with error codes on `FrameError` and `MessageError`
- Suppress response body for HEAD requests per RFC 9114 §4.1
- Allow `te: trailers` header in requests per RFC 9114 §4.2
- Custom ALPN support (no longer hardcoded to `h3`)
- `Stream` and `StreamEvent` abstractions to encapsulate C extension details
- Dual-stack (IPv4/IPv6) listener support — fixes TLS handshake failures on macOS
- Client `PUT` method
- Integration test suite for curl HTTP/3

### Fixed
- Memory leaks: free `StreamContext` on `SHUTDOWN_COMPLETE`, free `ConnectionContext` on `CONNECTION_SHUTDOWN_COMPLETE`, close `EventQ`/`ExecContext`/`WakeFd` on shutdown
- Double-free and handle leaks in C extension
- `dispatch_to_ruby` safety with `rb_protect`; client use-after-free fix
- Infinite loop on truncated varint in request/response parsers
- Frame ordering: `DATA` before `HEADERS` now raises `FrameError`
- `STOP_SENDING` / `STREAM_RESET` compliance — server properly cancels streams and resets send side
- Control stream validation: reject duplicate settings, forbidden frame types, and reserved HTTP/2 types
- QPACK static table index 57/58 casing (`includeSubDomains`)
- Stale stream handle guard in cancel and C extension
- Replaced `Thread.kill` with `Thread.raise(DrainTimeoutError)` for clean drain
- Binary encoding for `buffer_data` and empty FIN handling
- Linux/GitHub CI: use epoll instead of kqueue on non-Darwin platforms
- Circular require warning

### Changed
- Reorganized gem structure: `protocol/`, `server/`, `transport/` directories
- Server owns the 0-RTT policy
- QPACK encoder uses O(1) static table lookup with multi-level caching
- QPACK decoder uses string-based decoding with result caching
- HTTP/3 parsers optimized with parse-level caching and lazy allocation
- Varint encoding/decoding optimized with precomputed tables
- HTTP/3 encoders handle framing only; QPACK handles field encoding (cleaner separation)
- MsQuic custom execution mode with configurable worker pool and throughput settings

### Limitations
- Client does not reuse connections

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
