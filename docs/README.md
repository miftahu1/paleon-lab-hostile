# Site 7 documentation index

- [Architecture and hostname map](ARCHITECTURE.md)
- [API behavior](API.md)
- [Deployment configuration (reference only)](DEPLOYMENT.md)
- [DNS rebinding and deferred zone-transfer design](dns-rebinding.md)
- [Isolation](isolation.md)
- [Malformed protocols](malformed-protocols.md)
- [Port map](port-map.md)
- [Resource exhaustion](resource-exhaustion.md)
- [Operations](OPERATIONS.md)
- [Threat model](threat-model.md)
- [Validation matrix](test-matrix.md)

Site 7 targets scanner resilience with passive hostile inputs. It does not crawl links, so every stimulus has an independent hostname and every path on a hostname returns its stimulus. AWS region is `eu-west-2`; use the Sites 1–6 lab account, never the Paleon SaaS/application account. No deployment, DNS changes, public certificate, Paleon verification, or live scan is part of repository validation.
