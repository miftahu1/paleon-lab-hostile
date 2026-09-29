# Port map

| Port | Bind / service | Public | Role |
|---|---|---|---|
| 22/TCP | SSH | Admin CIDR only | Operator access |
| 53/TCP+UDP | DNS daemon on `0.0.0.0` | Yes | Authoritative non-recursive rebinding fixture; Paleon scans TCP only, so TCP/53 alone is an expected exposed-port finding (not UDP/53) |
| 80/TCP | Nginx | Yes | Redirects to HTTPS |
| 443/TCP | Nginx stream SNI router | Yes | Normal HTTPS and hostile raw TLS/HTTP fixtures |
| 5000/TCP | Flask `127.0.0.1` | No | Host-header dispatch, health and local observation API |
| 8443/TCP | Nginx `127.0.0.1` | No | HTTPS termination / Flask proxy |
| 8444/TCP | Nginx `127.0.0.1` | No | Dedicated OFFSCOPE_DOMAIN HTTPS termination; listener exists only after trusted ACME issuance |
| 9997/TCP | Slow TLS `127.0.0.1` | No | Delayed handshake |
| 9998/TCP | Malformed TLS `127.0.0.1` | No | Garbled ServerHello |
| 9999/TCP | Malformed HTTP `127.0.0.1` | No | Valid TLS followed by malformed HTTP bytes |

SNI sends `malformed-tls` to 9998, `malformed-http` to 9999, `slow-tls` to 9997, ordinary hostile HTTPS hosts to 8443 then Flask, and `OFFSCOPE_DOMAIN` to 8444. The off-scope block and listener are activated only after its dedicated trusted ACME certificate is issued; otherwise HTTPS fails closed and the health gate fails. When active, it returns a fixed plain-text response without reaching Flask. Proxy buffering is off and finite streaming timeouts are 660 seconds. Nginx blocks `/internal/site7-observation` on public HTTPS and the off-scope sink; direct host operator access remains `http://127.0.0.1:5000/internal/site7-observation`.

The loopback destinations listed here describe listener bindings. The egress policy separately rejects new outbound `site7` UID connections and permits only established/reply traffic. See [isolation.md](isolation.md).
