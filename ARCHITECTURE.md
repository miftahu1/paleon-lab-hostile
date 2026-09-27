# Site 7 architecture

The scanner discovers hosts and requests root plus a fixed path set; it does not crawl links. Every hostile stimulus is assigned a separate hostname and every path on that hostname returns the same stimulus. Nginx SNI routes malformed TLS, malformed HTTP, and slow TLS to dedicated raw TCP services. Other HTTPS traffic terminates at Nginx and reaches Flask, which dispatches using the Host header.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the authoritative hostname/stimulus map, certificate SAN policy, request flow, and port map. See [docs/isolation.md](docs/isolation.md) for egress controls and [docs/dns-rebinding.md](docs/dns-rebinding.md) for the authoritative rebinding behavior.

All fixtures are passive from the target's perspective. Redirect destinations are emitted as `Location` headers only. The application has no outbound HTTP client, IAM role, real credentials, malware, or third-party mutation behavior. Resource responses are finite: 20 MB large-body ceiling, 15 second kill hold, and 60 one-byte slow-drip chunks at 10 second intervals (maximum 10 minutes).
