# DNS rebinding fixture (SAFE-007)

`rebind-test.paleon-lab-hostile.com` is delegated to `ns1.paleon-lab-hostile.com`, which points to the Site 7 EIP. The daemon listens on TCP and UDP 53, is authoritative and non-recursive (AA set, RA clear), and is bounded by worker/semaphore and client-state limits.

For each source client IP, first A answer is configured `SITE7_EIP`; every subsequent A answer is `192.168.1.1`. Counters cap without wraparound, so no later answer returns to the public IP. Other query types are answered without advancing the A counter. Every query logs timestamp, source IP, qname, qtype, answer/outcome, per-client counter, and total A-query counter. The server does not infer scanner identity; recursive resolvers may be the observed source and logs are correlated later with scanner-side evidence.

The validation script's Stage A queries the authoritative EIP directly and checks first/public then second/private answers plus AA/RA flags. Stage B uses the system resolver; if caching or delegation prevents an observed transition, it reports that honestly rather than claiming Stage A proves the system resolver path.

Do not include rebind-test in the certificate because its DNS answers intentionally alternate. The `ns1` hostname is DNS infrastructure only and is not a SAN. A zone-transfer fixture is postponed: future design is an additional apex nameserver with an A record to a private IP such as `10.0.0.1`; do not add it to active Terraform because it may disrupt resolution.
