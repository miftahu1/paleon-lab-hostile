# Malformed protocol fixtures

Paleon does not crawl links, so malformed behavior is hosted on dedicated names and must work at root and fixed paths. Nginx SNI sends `malformed-http.paleon-lab-hostile.com` to the valid-TLS/raw-HTTP backend on loopback 9999, and `malformed-tls.paleon-lab-hostile.com` to the raw garbled-handshake backend on loopback 9998. Both hosts are included in the ordinary certificate SAN set. The `slow-tls` host is also a SAN and routes to its bounded delay fixture on 9997.

The HTTP fixture returns invalid chunk framing or control bytes/length mismatch after TLS. The TLS fixture emits deliberately invalid handshake bytes. These fixtures are bounded in concurrency and time. They are test inputs only: no real malware, arbitrary outbound request, external-system modification, credentials, or cloud metadata access is implemented.
