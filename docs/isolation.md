# Isolation model

Site 7 is a passive protocol/input fixture. It never makes arbitrary third-party requests, follows its SSRF redirects, accesses AWS metadata, uses IAM credentials, attacks external systems, or modifies third-party systems. No real credentials or malware are included. No IAM instance profile is attached.

The service user `site7` has reply-only outbound networking. A persistent iptables/ip6tables chain first accepts only ESTABLISHED/RELATED traffic, explicitly rejects metadata, RFC1918, loopback, IPv6 ULA and link-local destinations, then rejects NEW connections for that UID. These rules are installed before any Site 7 unit; the firewall systemd unit is enabled, ordered before `network-pre.target`, and required by Flask, DNS, malformed-protocol, and Nginx units. Bootstrap package installation occurs as root before target services start.

Loopback firewall rules block outbound destinations `127.0.0.0/8` and `::1/128` for processes owned by `site7`; they do not prevent Nginx from accepting inbound localhost proxy connections. Host-local service bindings are separate from outbound policy. Security-group public ingress is TCP 22 from admin CIDR, TCP/UDP 53, TCP 80, and TCP 443.

Flask, internal HTTPS, and malformed/slow TLS backends bind loopback. The observation API's Flask localhost check is defense in depth; public Nginx also returns 404 for that path because proxying otherwise makes the Flask peer appear local. Operator access remains direct to `127.0.0.1:5000`.

All response limits are finite: large body maximum 20 MB, slow body maximum 15 seconds, gzip expansion maximum 10 MB, kill-test hold 15 seconds, slow-drip 60 bytes over at most 10 minutes, DNS client state 100 clients and query counters capped without resetting to a public answer, and bounded DNS/raw-protocol concurrency.
