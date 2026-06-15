# Connection identity and QUIC routing IDs

## Rack request identity

Rack apps receive these env values:

- `env["quicsilver.connection_id"]`
  - Opaque QUIC connection identity.
  - Stable across requests/streams on the same QUIC connection.
  - Currently backed by MsQuic's original destination connection ID.
  - Do not parse this for load-balancing or backend routing decisions.

- `env["quicsilver.stream_id"]`
  - QUIC stream id for this HTTP/3 request.
  - Different requests on the same connection have different stream ids.

- `env["quicsilver.request_id"]`
  - Recommended app/log/correlation identity.
  - Format without fixed server id:
    - `<connection_id>:<stream_id>`
  - Format with fixed server id:
    - `<transport_server_id>:<connection_id>:<stream_id>`
  - This is the value applications and middleware should prefer.

Quicsilver does not expose separate Rack env fields for transport-only routing metadata such as `transport_server_id` or the original destination CID. Use `quicsilver.request_id` for request correlation.

## Fixed MsQuic Server ID

`transport_server_id` configures MsQuic's fixed 4-byte Server ID.

- Purpose:
  - Allows QUIC-aware load balancers to route using the server id embedded in MsQuic-generated connection IDs.
  - Useful after the server has generated CIDs for an established connection.

- Configuration:

  ```ruby
  config = Quicsilver::Transport::Configuration.new(
    cert_file,
    key_file,
    transport_server_id: "01020304"
  )
  ```

- Rules:
  - Must be exactly 4 bytes encoded as 8 hex characters.
  - Hex is normalized to lowercase.
  - Server startup applies this before MsQuic is opened.
  - This is MsQuic process-global state, so set it once per server process/pod.

- Common deployment pattern:

  ```ruby
  config = Quicsilver::Transport::Configuration.new(
    cert_file,
    key_file,
    transport_server_id: ENV["QUICSILVER_TRANSPORT_SERVER_ID"]
  )
  ```

  ```sh
  QUICSILVER_TRANSPORT_SERVER_ID=01020304 bundle exec ruby server.rb
  ```

When configured, Rack request ids include the server id prefix:

```text
01020304:7f9a23c001de88b0:4
```

## CIBIR ID

`cibir_id` configures MsQuic CIBIR: Connection ID Based Implicit Routing.

- Purpose:
  - Provides routing bytes in the client's destination connection ID.
  - Useful for routing the first packet/initial connection to the right listener or shard.
  - The meaning of the bytes is application/load-balancer defined.

- Server/listener configuration:

  ```ruby
  config = Quicsilver::Transport::Configuration.new(
    cert_file,
    key_file,
    cibir_id: "0a"
  )
  ```

- Client configuration:

  ```ruby
  client = Quicsilver::Client.new(
    "example.com",
    4433,
    transport_cibir_id: "0a"
  )
  ```

- Rules:
  - Must be 1..6 bytes encoded as an even-length hex string.
  - Hex is normalized to lowercase.
  - MsQuic currently supports CIBIR at offset `0` only.
  - CIBIR must be configured consistently on both ends:
    - Server/listener: `cibir_id: "0a"`
    - Client: `transport_cibir_id: "0a"`
  - If one side uses CIBIR and the other side does not, MsQuic rejects the connection during handshake.
  - If the client sends the wrong CIBIR bytes, packets may not route to the configured listener/backend.
  - CIBIR is transport routing configuration, not Rack request identity.

## How the pieces differ

- `cibir_id`
  - Client-selected routing bytes.
  - Used at listener/connection start time.
  - Helps route initial packets before server-generated CIDs matter.

- `transport_server_id`
  - Server-selected fixed 4-byte id.
  - Embedded by MsQuic in server-generated CIDs.
  - Helps QUIC-aware load balancers route established connections by backend/server.

- `connection_id`
  - App-facing opaque connection identity.
  - Stable across streams on the same QUIC connection.
  - Not guaranteed to be the same CID a load balancer sees on the wire.

- `stream_id`
  - Per-request QUIC stream identity.

- `request_id`
  - App-facing request correlation value.
  - Combines the stable connection identity and stream id.
  - Includes `transport_server_id` as a prefix when configured.

## Recommended usage

- Log `env["quicsilver.request_id"]` for application request correlation.
- Treat `env["quicsilver.connection_id"]` as opaque.
- Configure `transport_server_id` when QUIC-aware infrastructure needs backend routing by server-generated CIDs.
- Configure `cibir_id` / `transport_cibir_id` together when client-chosen destination CID bytes are part of your routing scheme.
