# PALEON TEST SITE 7 — Network Isolation Model

## Overview

Site 7 implements a defense-in-depth isolation model to ensure the hostile test target cannot reach real internal assets, production infrastructure, or any sensitive resources.

---

## 1. Network Architecture

### AWS Deployment (Production)

```
┌───────────────────────────────────────────────────────────────┐
│                        AWS REGION (us-east-1)                 │
│  ┌───────────────────────────────────────────────────────┐    │
│  │                   DEFAULT VPC                         │    │
│  │  ┌────────────────────────────────────────────────┐   │    │
│  │  │              SUBNET (public)                   │   │    │
│  │  │  ┌──────────────────────────────────────────┐  │   │    │
│  │  │  │          EC2 INSTANCE                    │  │   │    │
│  │  │  │  - paleon-site7-instance                 │  │   │    │
│  │  │  │  - Ubuntu 24.04 LTS                      │  │   │    │
│  │  │  │  - NO IAM INSTANCE PROFILE               │  │   │    │
│  │  │  │  - Security Group: paleon-site7-sg       │  │   │    │
│  │  │  │  - Elastic IP attached                   │  │   │    │
│  │  │  └──────────────────────────────────────────┘  │   │    │
│  │  └────────────────────────────────────────────────┘   │    │
│  └───────────────────────────────────────────────────────┘    │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                   ROUTE 53                              │  │
│  │  - paleon-lab-hostile.com            -> EIP             │  │
│  │  - offscope.paleon-lab-hostile.com   -> EIP             │  │
│  │  - malformed-http.paleon-lab-hostile.com -> EIP         │  │
│  │  - malformed-tls.paleon-lab-hostile.com -> EIP          │  │
│  │  - ns1.paleon-lab-hostile.com        -> EIP (NS glue)   │  │
│  │  - rebind-test.paleon-lab-hostile.com -> NS ns1...      │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

### Local Development / Verification (single-instance, no container stack)

```
┌──────────────────────────────────────────────────────────────┐
│                     SINGLE INSTANCE                          │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐  │
│  │   Nginx      │ │  Flask App   │ │ Malformed TLS :9998  │  │
│  │  :80/:443    │ │  :5000       │ │ (127.0.0.1 only)     │  │
│  └──────┬───────┘ └──────┬───────┘ └──────────────────────┘  │
│         │                │                                    │
│         │          ┌─────┴─────┐                              │
│         │          ▼           ▼                              │
│         │  ┌────────────┐ ┌────────────┐                      │
│         │  │ :8443      │ │ Malformed  │                      │
│         │  │ (internal  │ │ HTTP :9999 │                      │
│         │  │  TLS term) │ │ (127.0.0.1)│                      │
│         │  └────────────┘ └────────────┘                      │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ DNS Rebind   │                                            │
│  │ Server :53   │                                            │
│  │ (0.0.0.0)    │                                            │
│  └──────────────┘                                            │
└──────────────────────────────────────────────────────────────┘
```

**Note**: There is no container stack. Site 7 is a single Ubuntu 24.04 EC2 instance running three Python services under systemd behind Nginx.

---

## 2. Security Group Rules

### Ingress Rules

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 80 | TCP | 0.0.0.0/0 | HTTP test endpoints (redirects to 443) |
| 443 | TCP | 0.0.0.0/0 | HTTPS test endpoints (SNI routing) |
| 53 | TCP | 0.0.0.0/0 | DNS rebinding test entry |
| 53 | UDP | 0.0.0.0/0 | DNS rebinding test entry |
| 22 | TCP | `admin_ip` (variable) | SSH admin access only |

### Egress Rules

**Security-group egress** is left at the AWS default (all outbound allowed). This is required so the bootstrap can `apt-get install` and `pip install` from public mirrors.

| Layer | Rule | Purpose |
|-------|------|---------|
| Security group | All outbound allowed (AWS default) | Bootstrap package / dependency downloads |
| Host firewall (`site7` uid) | `REJECT` to RFC1918, link-local, IPv6 ULA/link-local | Application-user egress isolation |

**Host-level egress isolation.** The SG stays open, but the unprivileged `site7` service user is confined at the host level. `site7-egress-firewall.service` — a `systemd` oneshot ordered `Before=network-pre.target` — installs `iptables`/`ip6tables` `owner --uid-owner site7` rules that `REJECT` traffic originating from the `site7` user to:

- `169.254.0.0/16` (link-local / cloud metadata)
- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC1918)
- `fc00::/7`, `fe80::/10` (IPv6 ULA / link-local)

Because the rules are installed by an **enabled** `systemd` unit ordered before networking, they are reinstalled on every boot — the isolation **persists across reboot** rather than living only in the running kernel. Root and other system users keep the outbound access that bootstrap and package updates need; only the application user is confined.

This is defense in depth: the application code also makes **zero outbound calls** (enforced in code and checked by `validate.sh`). Even if that code changed, the host firewall would still block the `site7` user from reaching metadata and private ranges.

---

## 3. IAM Permissions

### Instance Profile

**NONE** — The EC2 instance has **no IAM instance profile or role attached**.

This means:
- ❌ No `ec2:DescribeInstances`
- ❌ No `ssm:GetParameters`
- ❌ No `secretsmanager:GetSecretValue`
- ❌ No `s3:GetObject`
- ❌ No `sts:AssumeRole`
- ❌ No permissions whatsoever

The instance can only use its IMDSv2 token to get its own metadata (instance ID, region, etc.) — but the application code **never calls IMDS**.

---

## 4. Application-Level Isolation

### No Outbound Network Calls

The Flask application (`app/app.py`) and supporting servers contain **no outbound network code**:

```bash
# Verified absent:
grep -r "requests.get" app/
grep -r "urllib" app/
grep -r "httpx" app/
grep -r "socket.connect" app/
grep -r "curl" app/
grep -r "wget" app/
# All return no matches
```

### Localhost-Only Listeners

| Service | Port | Bind Address | Exposure |
|---------|------|--------------|----------|
| Flask App | 5000 | 127.0.0.1 | Internal only (via Nginx 8443) |
| Nginx Internal TLS | 8443 | 127.0.0.1 | Internal only (default SNI backend) |
| Malformed TLS Server | 9998 | 127.0.0.1 | Internal only (via SNI on 443) |
| Malformed HTTP Server | 9999 | 127.0.0.1 | Internal only (via SNI on 443) |
| DNS Rebinding Server | 53 | 0.0.0.0 | **Public** (authoritative DNS for rebind-test) |
| Nginx Public | 80, 443 | 0.0.0.0 | **Public** (scanner entry points) |

The malformed protocol servers and Flask app **only bind to 127.0.0.1**. They are not accessible from the network directly — all traffic goes through Nginx on ports 80/443 with SNI routing.

### No Secrets or Credentials

- No AWS credentials in environment
- No database passwords
- No API keys
- No GitHub tokens
- No service account keys
- No `.env` files
- No credentials in code

---

## 5. Why the Target Cannot Reach Real Internal Assets

### 1. No Network Path
- Default VPC has no VPC peering connections
- No Transit Gateway attachments
- No VPN connections
- No Direct Connect
- No route to any private network beyond the VPC CIDR

### 2. No Credentials to Authenticate
- No IAM role → cannot call AWS APIs
- No SSH keys to other instances
- No database credentials
- No service mesh tokens

### 3. Host Firewall Blocks the Application User
The SG allows all outbound by default, but the `site7` user is confined by host `iptables`/`ip6tables` `owner --uid-owner` rules that `REJECT` RFC1918, link-local, and IPv6 ULA/link-local destinations (see §2), reinstalled on every boot. Defense in depth: the application code also contains no `requests`, `httpx`, `urllib`, or socket-connect code, so it makes no outbound calls even where the firewall would allow them.

### 4. Metadata Service Access is Impossible
- IMDS (169.254.169.254) is accessible from any EC2 instance
- **However**: The application never calls it
- The test endpoints *return redirect URLs pointing to IMDS* — but the target never follows them
- The **scanner** is the one being tested to see if it follows them

### 5. No Shared Infrastructure
- Dedicated security group (not shared with Sites 1-6)
- Dedicated instance (not shared)
- Dedicated Elastic IP
- Dedicated Route53 records
- No shared filesystems, databases, or message queues

---

## 6. Network Segmentation Summary

| Layer | Isolation Mechanism |
|-------|---------------------|
| **Network** | Default VPC, no peering, no transit gateway, no VPN |
| **Security Group** | Minimal ingress (80/443/53 public, 22 admin only); default (open) egress for bootstrap |
| **Host Firewall** | `site7` uid `REJECT` to RFC1918 / link-local / IPv6 ULA — reboot-persistent via systemd oneshot |
| **IAM** | No instance profile — zero AWS permissions |
| **Application** | No outbound network code; 127.0.0.1-only internal servers |
| **DNS** | Lab-controlled zone; rebind test uses separate controlled hostname |
| **Runtime** | No secrets, no credentials, no external dependencies |
| **Process** | Separate processes for malformed/DNS tests; no shared state |

---

## 7. Verification of Isolation

### Pre-Deployment Checks (validate.sh)
- [ ] No IAM role in Terraform
- [ ] Security group has no shared references
- [ ] No hardcoded credentials
- [ ] Application code has no outbound network calls

### Post-Deployment Checks (verify.sh)
- [ ] Instance has no IAM profile: `aws ec2 describe-instances --instance-ids <id> | grep IamInstanceProfile` (should be empty)
- [ ] Security group rules match spec
- [ ] Only expected ports listening
- [ ] No unexpected processes

### Runtime Verification
```bash
# 1. Verify no IAM role (from the AWS control plane, not from the instance):
aws ec2 describe-instances --instance-ids <id> \
  --query 'Reservations[].Instances[].IamInstanceProfile' --output text
# Should print "None" — no instance profile is attached.
# (IMDSv2 is required, so a token-less request to 169.254.169.254 returns 401, never credentials.)

# The remaining checks run on the instance itself:

# 2. Verify application makes no outbound calls
# (Check process network connections)
ss -tulpn | grep -E ":5000|:8443|:9998|:9999|:53"
# Should show only listening sockets, no ESTABLISHED outbound

# 3. Verify localhost-only binding for internal servers
ss -tulpn | grep 127.0.0.1
# Should show :5000, :8443, :9998, :9999 bound to 127.0.0.1 only
# Should show :53 bound to 0.0.0.0 (public)

# 4. Verify DNS rebinding is authoritative
dig @localhost rebind-test.paleon-lab-hostile.com
# Should return EIP (1st query) or 192.168.1.1 (subsequent)
```

---

## 8. Isolation Failure Modes (and Why They're Prevented)

| Failure Mode | Prevention |
|--------------|------------|
| Accidental VPC peering to production | Terraform creates no peering; manual action required |
| IAM role attached by mistake | Terraform explicitly omits `iam_instance_profile` |
| Shared security group | Terraform creates dedicated SG with unique name |
| Application updated to add outbound calls | Code review; validate.sh checks for outbound patterns |
| DNS zone shared with production | Dedicated hosted zone or explicit subdomain delegation |
| Credentials leaked via user_data | user_data.sh references no secrets; uses only public packages |
| Internal services exposed externally | All internal servers bind to 127.0.0.1; only Nginx/DNS on 0.0.0.0 |
| IMDS access by application | App reads PUBLIC_IP from SITE7_EIP env var, not IMDS |

---

## 9. Conclusion

The isolation model is **defense in depth**:
1. **Network**: No path to private networks
2. **Identity**: No IAM role = no AWS API access
3. **Application**: No outbound code = cannot initiate connections
4. **Runtime**: No secrets = nothing to steal
5. **Operational**: Dedicated resources = no noisy neighbor risk
6. **Binding**: Internal services on 127.0.0.1 only

Even if one layer fails, the others provide protection. The application code itself is the strongest barrier — it simply cannot make outbound connections by design.