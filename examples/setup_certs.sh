#!/bin/bash

# Quicsilver Certificate Setup
# This script generates self-signed certificates for QUIC testing

echo "🔐 Generating certificates for Quicsilver QUIC testing..."

# Create certs directory if it doesn't exist
mkdir -p ../certs
cd ../certs

# Create OpenSSL config with proper TLS server extensions
cat > openssl.conf << 'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost
O = QuicsilverTest
C = US

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

# Generate private key and certificate
echo "📝 Generating private key..."
openssl genrsa -out server.key 2048

echo "📜 Generating certificate..."
openssl req -new -x509 -key server.key -out server.crt -days 365 \
  -config openssl.conf -extensions v3_req

# Create PKCS#12 format (optional, for other tools)
echo "📦 Creating PKCS#12 bundle..."
openssl pkcs12 -export -out server.p12 -inkey server.key -in server.crt \
  -passout pass:password -name "localhost"

# Clean up
rm openssl.conf

echo "✅ Certificate files created:"
echo "   📄 server.crt - Certificate file"
echo "   🔑 server.key - Private key file"  
echo "   📦 server.p12 - PKCS#12 bundle (password: 'password')"
echo ""
echo "🚀 You can now run:"
echo "   Terminal 1: ruby examples/test_server.rb"
echo "   Terminal 2: ruby examples/test_connection.rb"