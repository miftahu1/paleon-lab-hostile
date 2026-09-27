# HTTP and DNS behavior

The scanner does not crawl links. It discovers each hostname and requests root plus fixed paths. Flask routes ordinary HTTPS by Host header; every path on each hostile hostname invokes that hostname's one stimulus. See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete host map.

`GET /health` is an operational health response. `GET /internal/site7-observation` returns bounded in-memory observations only when accessed directly at `http://127.0.0.1:5000`; public Nginx HTTPS explicitly returns 404 for this path. The observer stimulus accepts any method and path and returns 200; the safety expectation is that a normal scanner itself uses only non-destructive methods, not that the target rejects writes.

Stimuli include metadata/private-address redirects, two redirect-loop shapes, bounded large/slow/gzip bodies, a 15-second held connection, an FTP redirect, one byte per 10 seconds for at most 10 minutes, delayed TLS, malformed HTTP/TLS, and SAFE-001 redirect to operator-configured `OFFSCOPE_DOMAIN`. The second domain must be separately registered, never verified in Paleon, and never added as a business-context host.

DNS on TCP and UDP port 53 is authoritative and non-recursive for `rebind-test.paleon-lab-hostile.com`: the first A query per client returns the configured public EIP; subsequent A queries return `192.168.1.1` permanently for that client (no wraparound). All query types are logged with timestamp, source IP, qname, qtype, answer, and client/query counters. Resolver source IPs may differ from the scanner; do not infer scanner identity from these logs.
