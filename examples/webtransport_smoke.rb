#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal browser WebTransport smoke test.
#
#   ruby examples/webtransport_smoke.rb
#   open https://localhost:8443/
#
# Chrome discovers HTTP/3 using Alt-Svc from a normal HTTPS/TCP origin. This
# example therefore starts two servers:
#
# - Tiny HTTPS/TCP server on https://localhost:8443 serving this page + Alt-Svc.
# - Quicsilver HTTP/3/UDP on localhost:8443 handling the same origin via Alt-Svc.
#
# It intentionally avoids Rails, framing, endpoints, and stress testing. It only
# answers: does browser WebTransport reach Rack as
# env["quicsilver.context"].webtransport, can we accept it, and can one bidi
# stream echo bytes?

require_relative "example_helper"
require "openssl"
require "socket"
require "tmpdir"

HTTPS_PORT = Integer(ENV.fetch("HTTPS_PORT", "8443"))
H3_PORT = Integer(ENV.fetch("H3_PORT", HTTPS_PORT.to_s))
HOST = ENV.fetch("HOST", "quicsilver.test")
ALT_SVC = %(h3=":#{H3_PORT}"; ma=3600)
CERT_DIR = File.dirname(EXAMPLE_TLS_CONFIG.cert_file)
ISSUER_CERT = File.join(CERT_DIR, "development.crt")
PAGE_CERT = ENV.fetch("PAGE_CERT") { File.join(CERT_DIR, "#{HOST}.crt") }
PAGE_KEY = ENV.fetch("PAGE_KEY") { File.join(CERT_DIR, "#{HOST}.key") }
PAGE_CERT = EXAMPLE_TLS_CONFIG.cert_file unless File.exist?(PAGE_CERT)
PAGE_KEY = EXAMPLE_TLS_CONFIG.key_file unless File.exist?(PAGE_KEY)

CERT_FILE = File.join(Dir.tmpdir, "quicsilver-#{HOST}-short.crt")
KEY_FILE = File.join(Dir.tmpdir, "quicsilver-#{HOST}-short.key")

key = OpenSSL::PKey::EC.generate("prime256v1")
cert = OpenSSL::X509::Certificate.new
cert.version = 2
cert.serial = Random.rand(1..2**64)
cert.subject = OpenSSL::X509::Name.parse("/CN=#{HOST}")
cert.issuer = cert.subject
cert.public_key = key
cert.not_before = Time.now - 60
cert.not_after = Time.now + (13 * 24 * 60 * 60)

extensions = OpenSSL::X509::ExtensionFactory.new
extensions.subject_certificate = cert
extensions.issuer_certificate = cert
cert.add_extension extensions.create_extension("basicConstraints", "CA:FALSE", true)
cert.add_extension extensions.create_extension("keyUsage", "digitalSignature", true)
cert.add_extension extensions.create_extension("extendedKeyUsage", "serverAuth", false)
cert.add_extension extensions.create_extension("subjectAltName", "DNS:#{HOST},DNS:localhost,IP:127.0.0.1,IP:::1", false)
cert.sign(key, OpenSSL::Digest::SHA256.new)

File.write(CERT_FILE, cert.to_pem)
File.write(KEY_FILE, key.to_pem)
CERT_SHA256 = [OpenSSL::Digest::SHA256.digest(cert.to_der)].pack("m0")
SMOKE_TLS_CONFIG = Quicsilver::Transport::Configuration.new(
  CERT_FILE,
  KEY_FILE,
  idle_timeout_ms: 120_000,
  keep_alive_interval_ms: 20_000,
  max_unidirectional_streams: 100
)

HTML = <<~HTML
  <!doctype html>
  <meta charset="utf-8">
  <title>Quicsilver WebTransport Smoke</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; }
    button { margin: .25rem; }
    pre { background: #111; color: #0f0; padding: 1rem; min-height: 16rem; white-space: pre-wrap; }
  </style>

  <h1>Quicsilver WebTransport Smoke</h1>

  <p>
    This page is served over HTTPS/TCP with <code>Alt-Svc: #{ALT_SVC}</code>.
    The browser should use HTTP/3 on UDP port #{H3_PORT} for WebTransport.
    TCP and UDP intentionally share the same port, matching production HTTPS/H3 deployments.
  </p>

  <button onclick="connectWT()">Connect WebTransport</button>
  <button onclick="sendBidi()">Open bidi stream + send hello</button>
  <button onclick="sendUni()">Open uni stream + send hello</button>
  <button onclick="sendDatagram()">Send datagram</button>
  <button onclick="closeWT()">Close</button>
  <button onclick="clearLog()">Clear</button>

  <pre id="log"></pre>

  <script type="module">
    let transport
    const encoder = new TextEncoder()
    const decoder = new TextDecoder()

    function log(message) {
      console.log(message)
      document.getElementById("log").textContent += `${new Date().toISOString()} ${message}\n`
    }

    window.clearLog = function() {
      document.getElementById("log").textContent = ""
    }

    function wtURL() {
      return new URL("/wt", location.href).toString()
    }

    window.connectWT = async function() {
      try {
        log(`creating WebTransport ${wtURL()}`)
        log(`using serverCertificateHashes sha-256 #{CERT_SHA256}`)
        const certificateHash = Uint8Array.from(atob("#{CERT_SHA256}"), character => character.charCodeAt(0))
        transport = new WebTransport(wtURL(), {
          serverCertificateHashes: [{
            algorithm: "sha-256",
            value: certificateHash,
          }],
        })

        transport.closed.then(
          () => log("transport closed cleanly"),
          error => log(`transport closed with error: ${error}`)
        )

        log("waiting for ready")
        await transport.ready
        log("ready")
      } catch (error) {
        log(`connect failed: ${error.stack || error}`)
      }
    }

    window.sendBidi = async function() {
      try {
        if (!transport) await connectWT()

        log("creating bidirectional stream")
        const stream = await transport.createBidirectionalStream()
        const writer = stream.writable.getWriter()
        const reader = stream.readable.getReader()

        const message = `hello from browser ${Date.now()}`
        log(`writing: ${message}`)
        await writer.write(encoder.encode(message))
        await writer.close()

        log("waiting for echo")
        while (true) {
          const { value, done } = await reader.read()
          if (done) {
            log("reader done")
            break
          }

          log(`read: ${decoder.decode(value)}`)
        }
      } catch (error) {
        log(`send failed: ${error.stack || error}`)
      }
    }

    window.sendUni = async function() {
      try {
        if (!transport) await connectWT()

        log("creating unidirectional stream")
        const stream = await transport.createUnidirectionalStream()
        const writer = stream.getWriter()

        const message = `hello uni from browser ${Date.now()}`
        log(`writing uni: ${message}`)
        await writer.write(encoder.encode(message))
        await writer.close()
        log("uni writer closed")
      } catch (error) {
        log(`uni failed: ${error.stack || error}`)
      }
    }

    window.sendDatagram = async function() {
      try {
        if (!transport) await connectWT()

        const message = `datagram from browser ${Date.now()}`
        log(`sending datagram: ${message}`)
        const writer = transport.datagrams.writable.getWriter()
        await writer.write(encoder.encode(message))
        writer.releaseLock()

        log("waiting for datagram echo")
        const reader = transport.datagrams.readable.getReader()
        const { value, done } = await reader.read()
        reader.releaseLock()

        if (done) {
          log("datagram reader done")
        } else {
          log(`datagram read: ${decoder.decode(value)}`)
        }
      } catch (error) {
        log(`datagram failed: ${error.stack || error}`)
      }
    }

    window.closeWT = function() {
      if (transport) {
        log("closing transport")
        transport.close()
        transport = null
      }
    }
  </script>
HTML

app = lambda do |env|
  path = env["PATH_INFO"]
  method = env["REQUEST_METHOD"]
  context = env["quicsilver.context"]
  session = context&.webtransport || env["quicsilver.webtransport"]

  puts "H3 HTTP #{method} #{path} authority=#{env['HTTP_HOST']} protocol=#{env['SERVER_PROTOCOL']} wt=#{!!session} context=#{context.class if context}"

  if path == "/wt"
    unless session
      puts "WT endpoint hit without WebTransport session"
      next [426, { "content-type" => "text/plain", "alt-svc" => ALT_SVC }, ["No WebTransport session\n"]]
    end

    puts "WT session arrived path=#{session.path.inspect} authority=#{session.authority.inspect} stream_id=#{session.stream_id}"
    session.accept!
    puts "WT session accepted"

    session.on_stream do |stream|
      puts "WT accepted bidi stream id=#{stream.stream_id}"

      stream.on_data do |chunk|
        puts "WT stream #{stream.stream_id} read #{chunk.bytesize} bytes"
        response = "echo: #{chunk}"
        stream.write(response)
        stream.close
        puts "WT stream #{stream.stream_id} wrote #{response.bytesize} bytes"
      rescue => error
        warn "WT stream #{stream.stream_id} error: #{error.class}: #{error.message}"
        warn error.backtrace&.first(5)&.join("\n")
      end
    end

    session.on_uni_stream do |stream|
      puts "WT accepted uni stream id=#{stream.stream_id}"

      stream.on_data do |chunk|
        puts "WT uni stream #{stream.stream_id} read #{chunk.bytesize} bytes"
      rescue => error
        warn "WT uni stream #{stream.stream_id} error: #{error.class}: #{error.message}"
        warn error.backtrace&.first(5)&.join("\n")
      end

      stream.on_close do
        puts "WT uni stream #{stream.stream_id} closed"
      end
    end

    session.on_datagram do |datagram|
      puts "WT datagram read #{datagram.bytesize} bytes"
      response = "echo: #{datagram}"
      session.send_datagram(response)
      puts "WT datagram wrote #{response.bytesize} bytes"
    rescue => error
      warn "WT datagram error: #{error.class}: #{error.message}"
      warn error.backtrace&.first(5)&.join("\n")
    end

    session.on_close do
      puts "WT session closed"
    end

    next [200, { "alt-svc" => ALT_SVC }, []]
  end

  [200, { "content-type" => "text/html", "alt-svc" => ALT_SVC }, [HTML]]
end

h3_server = Quicsilver::Server.new(H3_PORT, app: app, server_configuration: SMOKE_TLS_CONFIG)
h3_thread = Thread.new { h3_server.start }

https_server = TCPServer.new(HOST, HTTPS_PORT)
ssl_context = OpenSSL::SSL::SSLContext.new
ssl_context.cert = OpenSSL::X509::Certificate.new(File.read(PAGE_CERT))
ssl_context.extra_chain_cert = [OpenSSL::X509::Certificate.new(File.read(ISSUER_CERT))] if File.exist?(ISSUER_CERT)
ssl_context.key = OpenSSL::PKey.read(File.read(PAGE_KEY))
ssl_server = OpenSSL::SSL::SSLServer.new(https_server, ssl_context)

https_thread = Thread.new do
  loop do
    begin
      socket = ssl_server.accept
    rescue OpenSSL::SSL::SSLError => error
      warn "HTTPS accept error: #{error.class}: #{error.message}"
      next
    end

    Thread.new(socket) do |client|
      begin
        request_line = client.gets&.strip
        puts "HTTPS #{request_line}" if request_line

        # Drain request headers.
        client.gets until $_ == "\r\n" || $_ == "\n" || $_.nil?

        body = HTML
        headers = [
          "HTTP/1.1 200 OK",
          "content-type: text/html; charset=utf-8",
          "content-length: #{body.bytesize}",
          "alt-svc: #{ALT_SVC}",
          "connection: close",
          "",
          ""
        ].join("\r\n")

        client.write(headers)
        client.write(body)
      rescue => error
        warn "HTTPS server error: #{error.class}: #{error.message}"
      ensure
        client.close rescue nil
      end
    end
  end
rescue IOError, SystemCallError
end

trap("INT") do
  puts "\nStopping..."
  https_server.close rescue nil
  h3_server.stop
end

puts "🚇 WebTransport smoke test"
puts "   Page:         https://#{HOST}:#{HTTPS_PORT}/   (HTTPS/TCP + Alt-Svc)"
puts "   WebTransport: https://#{HOST}:#{HTTPS_PORT}/wt (H3 UDP :#{H3_PORT})"
puts "   Alt-Svc:      #{ALT_SVC}"
puts "   Page cert:    #{PAGE_CERT}"
puts "   Page key:     #{PAGE_KEY}"
puts "   WT cert:      #{CERT_FILE}"
puts "   WT key:       #{KEY_FILE}"
puts "   WT SHA256:    #{CERT_SHA256}"
puts "   /etc/hosts:   127.0.0.1 #{HOST}"
puts "   Watch this terminal and the browser console."
puts

https_thread.join
h3_thread.join(2)
