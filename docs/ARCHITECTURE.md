# Architecture and hostname map

Paleon discovers hosts and fetches root plus a fixed set of paths; it does not crawl links. Each stimulus has its own hostname. Flask dispatches on the Host header, and all paths on a stimulus hostname use that hostname's handler. Nginx's stream/SNI router sends raw malformed TLS, malformed HTTP, and slow-TLS connections to their dedicated fixtures. Ordinary HTTPS terminates at the loopback Nginx listener and proxies to Flask.

## Ordinary hostile hosts

| Host | Stimulus on every path |
|---|---|
| `imds.paleon-lab-hostile.com` | 302 to `http://169.254.169.254/latest/meta-data/` (SSRF-002) |
| `fargate.paleon-lab-hostile.com` | 302 to `http://169.254.170.2/v2/credentials/TEST_ONLY` (SSRF-001) |
| `rfc1918.paleon-lab-hostile.com` | 302 to private IPv4 target (SSRF-003) |
| `loopback.paleon-lab-hostile.com` | 302 to `127.0.0.1` (SSRF-004) |
| `ipv6.paleon-lab-hostile.com` | 302 to IPv6 ULA `fd00::1` (SSRF-004-IPV6) |
| `redirect-loop.paleon-lab-hostile.com` | 302 cycle `/b` → `/c` → `/a` (SAFE-002) |
| `self-loop.paleon-lab-hostile.com` | 302 to the same URL (SAFE-002-SELF) |
| `large-body.paleon-lab-hostile.com` | Streamed body, default 10 MB, maximum 20 MB (SAFE-003) |
| `slow-body.paleon-lab-hostile.com` | Ten 1 KB chunks over a bounded delay (SAFE-003-SLOW) |
| `gzip-body.paleon-lab-hostile.com` | Valid gzip stream, maximum 10 MB decompressed (SAFE-003-GZIP) |
| `observer.paleon-lab-hostile.com` | Accepts any method, records bounded observation, returns 200 (SAFE-005) |
| `kill-test.paleon-lab-hostile.com` | Streams greeting, holds 15 seconds, then closes (SAFE-006) |
| `ftp-redirect.paleon-lab-hostile.com` | 302 to FTP scheme (SAFE-008) |
| `slow-drip.paleon-lab-hostile.com` | One byte every 10 seconds, at most 60 bytes / 10 minutes (SAFE-009) |
| `slow-tls.paleon-lab-hostile.com` | Delayed TLS handshake on raw backend (SAFE-010-TLS) |
| `malformed-http.paleon-lab-hostile.com` | Valid TLS followed by malformed HTTP bytes (SAFE-004) |
| `malformed-tls.paleon-lab-hostile.com` | Garbled TLS handshake (SAFE-004-TLS) |
| `offscope-redirect.paleon-lab-hostile.com` | 302 to configured `https://${OFFSCOPE_DOMAIN}/` (SAFE-001) |

`OFFSCOPE_DOMAIN` is a separate registered domain and is used only as the SAFE-001 redirect destination. It must never be verified in Paleon or added as a business-context host. It is operator-supplied; no purchased domain is encoded in this repository.

The same parameter configures an isolated Nginx HTTP/HTTPS sink server block, a separate HTTP-01 certificate lifecycle, and a dedicated access log. It is not added to the hostile subdomain list or normal Site 7 certificate SANs. Its A record is managed externally at its own DNS provider and must resolve to the Site 7 EIP before certificate issuance.

`rebind-test.paleon-lab-hostile.com` is DNS-only. `ns1.paleon-lab-hostile.com` is DNS infrastructure only. Neither is a certificate SAN: `rebind-test` intentionally alternates answers, while `ns1` does not host an ordinary HTTPS stimulus. Certificate SAN generation uses the centralized Terraform `hostile_subdomains` list plus the apex and excludes both names.

## Network layout

One Ubuntu 24.04 EC2 host has public TCP 22 (operator-supplied admin CIDR), 53, 80, and 443. DNS is authoritative and non-recursive: UDP binds `0.0.0.0:53`, while TCP binds the primary private IPv4 address discovered from the kernel default route. This avoids systemd-resolved loopback TCP/53 listeners, and remains reachable through EIP/NAT; Paleon's public TCP/53 probe reaches the TCP service. Nginx handles port 80 redirects and port 443 SNI routing. Loopback services are Flask `127.0.0.1:5000`, normal HTTPS proxy `127.0.0.1:8443`, slow TLS `127.0.0.1:9997`, malformed TLS `127.0.0.1:9998`, and malformed HTTP `127.0.0.1:9999`.

SAFE-006's 15-second held-response stimulus remains in the answer key and is executable using Paleon's running-scan Stop control; record the stop action, prompt termination, and absence of orphan processes or socket leaks.

The Flask observation API is intentionally available only via direct localhost access on port 5000. Nginx returns 404 for that exact path on public HTTPS, avoiding trust in a proxied `remote_addr` value.

Nginx uses `proxy_buffering off` for streamed fixtures and a finite 660 second proxy/stream idle timeout. Slow-drip emits an initial byte and each subsequent byte at 10 second intervals; public-boundary verification reads the first byte over 443 to confirm incremental delivery.

## Deferred DNS fixture

Do not activate the zone-transfer fixture in Terraform. Its future design is an additional nameserver hostname in the apex NS set with an A record pointing to a private address such as `10.0.0.1`. It stays postponed because it may interfere with DNS resolution.
