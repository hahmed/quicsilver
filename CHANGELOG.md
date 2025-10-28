# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-10-28

### Added
- Initial HTTP/3 server implementation using Microsoft MSQUIC
- HTTP/3 client for testing and development
- Rack support
- HTTP/3 frame encoding/decoding (DATA, HEADERS, SETTINGS)
- QPACK header compression (static table support)
- Bidirectional request/response streams
- Request body buffering for large payloads

### Limitations
This is still in prototype, it has the following known limitations:
- No server push, GOAWAY, or trailer support
- Limited error handling
