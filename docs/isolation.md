# PALEON TEST SITE 7 — Network Isolation Model

## Overview

Site 7 implements a defense-in-depth isolation model to ensure the hostile test target cannot reach real internal assets, production infrastructure, or any sensitive resources.

---

## 1. Network Architecture

### AWS Deployment

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS REGION (us-east-1)                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   DEFAULT VPC                           │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │              SUBNET (public)                    │   │   │
│  │  │  ┌──────────────────────────────────────────┐  │   │   │
│  │  │  │          EC2 INSTANCE                    │  │   │   │
│  │  │  │  - paleon-site7-instance                 │  │   │   │
│  │  │  │  - NO IAM INSTANCE PROFILE               │  │   │   │
│  │  │  │  - Security Group: paleon-site7-sg       │  │   │   │
│  │  │  │  - Elastic IP attached                   │  │   │   │
│  │  │  └──────────────────────────────────────────┘  │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   ROUTE 53                              │   │
│  │  - paleon-lab-hostile.com        -> EIP                 │   │
│  │  - offscope.paleon-lab-hostile.com -> EIP               │   │
│  │  - rebind-test.paleon-lab-hostile.com -> 93.184.216.34  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Local/Docker Deployment

```
┌─────────────────────────────────────────────────────────────────┐
│                        DOCKER NETWORK                           │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │
│  │   Nginx      │ │  Flask App   │ │ Malformed    │            │
│  │  :80/:443    │ │   :5000      │ │  Server :9999│            │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘            │
│         │                │                │                     │
│         └────────────────┼────────────────┘                     │
│                          ▼                                     │
│                 ┌──────────────┐                              │
│                 │ DNS Rebind   │                              │
│                 │  Server:5353 │                              │
│                 └──────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Security Group Rules

### Ingress Rules

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 80 | TCP | 0.0.0.0/0 | HTTP test endpoints |
| 443 | TCP | 0.0.0.0/0 | HTTPS test endpoints |
| 22 | TCP | `admin_ip` (variable) | SSH admin access only |

### Egress Rules

| Port | Protocol | Destination | Purpose |
|------|----------|-------------|---------|
| All | All | 0.0.0.0/0 | AWS default (required for package updates, dependency downloads during bootstrap) |

**Note**: No explicit egress restrictions are applied. The default AWS security group allows all outbound. This is intentional because:
1. Bootstrap needs `yum/dnf install` and `pip install`
2. The application itself makes **zero outbound calls** (enforced in code)
3. Adding explicit egress deny would break bootstrap

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
| Flask App | 5000 | 0.0.0.0 (behind Nginx) | Via Nginx 80/443 |
| Nginx | 80/443 | 0.0.0.0 | Public |
| Malformed Server | 9999 | 127.0.0.1 | Localhost only |
| DNS Rebind Server | 5353 (UDP) | 127.0.0.1 | Localhost only |

The malformed protocol server and DNS rebind server **only bind to 127.0.0.1**. They are not accessible from the network.

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

### 3. Security Group Blocks Internal Access (Implicit)
While the SG allows all outbound by default, the **application code itself prevents outbound calls**. Even if the SG allowed it, the Flask app has no `requests`, `httpx`, `urllib`, or socket connection code.

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
| **Network** | Dedicated VPC (default), no peering, no transit gateway |
| **Security Group** | Minimal ingress (80/443 public, 22 admin only), default egress |
| **IAM** | No instance profile — zero AWS permissions |
| **Application** | No outbound network code; localhost-only internal servers |
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
# From the instance itself:
# 1. Verify no IAM role
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>&1 | head -1
# Should return 404 or empty

# 2. Verify application makes no outbound calls
# (Check process network connections)
ss -tulpn | grep -E ":5000|:9999|:5353"
# Should show only listening sockets, no ESTABLISHED outbound

# 3. Verify localhost-only binding for internal servers
ss -tulpn | grep 127.0.0.1
# Should show :9999 and :5353 bound to 127.0.0.1 only
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

---

## 9. Conclusion

The isolation model is **defense in depth**:
1. **Network**: No path to private networks
2. **Identity**: No IAM role = no AWS API access
3. **Application**: No outbound code = cannot initiate connections
4. **Runtime**: No secrets = nothing to steal
5. **Operational**: Dedicated resources = no noisy neighbor risk

Even if one layer fails, the others provide protection. The application code itself is the strongest barrier — it simply cannot make outbound connections by design.