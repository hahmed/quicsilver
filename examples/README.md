# Quicsilver Examples

This directory contains examples for testing your Ruby QUIC implementation.

## 🚀 Quick Start

### 1. Generate Certificates

```bash
cd examples
./setup_certs.sh
```

This creates the necessary certificate files in the `certs/` directory.

### 2. Run the Server

```bash
# Terminal 1
ruby examples/test_server.rb
```

### 3. Test the Connection

```bash
# Terminal 2  
ruby examples/test_connection.rb
```

## 📁 Files

| File | Purpose |
|------|---------|
| `setup_certs.sh` | Generate certificates for testing |
| `test_server.rb` | Ruby QUIC server |
| `test_connection.rb` | QUIC client test |

## ✅ Expected Output

**Server:**
```
🔥 Quicsilver QUIC Server Test
════════════════════════════════════════
📋 Server Info:
   server_id: a47271c7ae4276d5
   address: 127.0.0.1
   port: 4433
   running: false
   cert_file: /path/to/certs/server.crt
   key_file: /path/to/certs/server.key
   max_connections: 100

🚀 Starting QUIC server on 127.0.0.1:4433
✅ QUIC server started successfully!
   🔗 Listening for connections...
🎯 Server is running! Press Ctrl+C to stop
```

**Client:**
```
🔗 Testing QUIC Connection to 127.0.0.1:4433...

Connected to 127.0.0.1:4433
✅ SUCCESS! Connected to QUIC server
   🕐 Connection time: 13.5ms
   📊 Connected status: true
   📋 Connection info: {"connected" => true, "failed" => false, ...}

🧪 Testing connection stability...
   ⏱️  Tick 1: Connected = true
   ⏱️  Tick 2: Connected = true  
   ⏱️  Tick 3: Connected = true
✅ Connection test completed!
🔒 Connection closed cleanly
```

## 🔧 Manual Certificate Setup

If you prefer to create certificates manually:

```bash
mkdir -p certs
cd certs

# Generate private key
openssl genrsa -out server.key 2048

# Generate certificate with proper QUIC extensions
openssl req -new -x509 -key server.key -out server.crt -days 365 \
  -subj "/CN=localhost/O=QuicsilverTest/C=US" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "extendedKeyUsage=serverAuth"
```

## 🐛 Troubleshooting

**Port in use error:** The server automatically cleans up port 4433 before starting.

**Connection refused:** Make sure the server is running before testing the client.

**Certificate errors:** Run `./setup_certs.sh` to regenerate certificates with proper QUIC extensions.

---

That's it! No Docker, no external servers, just pure Ruby QUIC. 🎯 