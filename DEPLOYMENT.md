# PALEON TEST SITE 7 — Deployment Guide

This document describes how to deploy PALEON TEST SITE 7 in an isolated environment.

## Prerequisites

- AWS account with permissions to create EC2, EIP, Route53 records, and Security Groups
- Terraform >= 1.5.0
- DNS zone for `paleon-lab-hostile.com` (or use a test domain)
- SSH key pair for EC2 access (optional but recommended)
- Approximately 15-20 minutes for deployment

## Deployment Steps

### 1. Clone Repository

```bash
git clone <repository-url>
cd C:/Users/mifta/Desktop/Paleon/Test Sites/hostile
```

### 2. Configure Variables

Create a `terraform.tfvars` file with your specific values:

```hcl
# Required variables
aws_region              = "us-east-1"
hostname                = "paleon-lab-hostile.com"
offscope_hostname       = "offscope.paleon-lab-hostile.com"
rebind_hostname         = "rebind-test.paleon-lab-hostile.com"
route53_zone_id         = "Z3M3LMPEXAMPLE"  # Your hosted zone ID
admin_ip                = "203.0.113.50/32"   # Your IP for SSH access
key_name                = "my-site7-key"      # Existing EC2 key pair name

# Optional variables (use defaults if not specified)
instance_type           = "t3.micro"
ami_id                  = "ami-0c101f26f147fa7fd"  # Amazon Linux 2023
project_name            = "paleon-site7"
```

> **Note**: The `route53_zone_id` is required. If you don't have a hosted zone, create one first in AWS Route53.

### 3. Initialize Terraform

```bash
cd terraform
terraform init
```

This initializes the local backend (state stored in `terraform.tfstate`).

### 4. Review Deployment Plan

```bash
terraform plan -var-file=../terraform.tfvars
```

Review the plan carefully. All resources will be created with the `paleon-site7` prefix.

### 5. Apply Deployment

```bash
terraform apply -var-file=../terraform.tfvars
```

Type `yes` when prompted. The deployment will:
- Create a security group allowing HTTP/HTTPS from anywhere and SSH from your admin IP only
- Launch an EC2 instance (t3.micro, Amazon Linux 2023) with NO IAM role
- Allocate and associate an Elastic IP
- Create Route53 A records for all three hostnames
- Execute the user data bootstrap script

### 6. Post-Deployment Verification

After approximately 5-10 minutes (for bootstrap completion), run:

```bash
../verify.sh
```

This script verifies:
- Services are reachable
- Hostname resolution works
- All test endpoints return correct headers
- No unexpected ports are exposed
- Systemd services are healthy

### 7. Accessing the Site

Once deployed, access via:
- Primary: https://paleon-lab-hostile.com
- Off-scope: https://offscope.paleon-lab-hostile.com
- Rebind test: rebind-test.paleon-lab-hostile.com (DNS only)

> **Important**: The off-scope and rebind hostnames point to the same server. The distinction is purely for testing scope enforcement and DNS rebinding scenarios.

## Local Development / Testing

For local testing without AWS:

### Using Docker Compose

```bash
docker compose up -d
```

This starts:
- Flask app on port 5000
- Malformed test server on port 9999
- DNS rebind server on port 5353
- Nginx reverse proxy on ports 80/443

Verify with:
```bash
../verify.sh
```

Reset with:
```bash
docker compose down -v
docker compose up -d
```

### Manual Python Execution

```bash
# Install dependencies
pip install -r app/requirements.txt

# Start services in separate terminals:
python app/app.py                    # Main Flask app
python app/malformed_server.py       # Malformed responses
python app/rebind_dns_server.py      # DNS rebind server
```

## Reset Procedures

### Full Infrastructure Reset

To destroy all AWS resources:

```bash
cd terraform
terraform destroy -var-file=../terraform.tfvars
```

This removes ALL resources created by Terraform. The Elastic IP will be released back to AWS.

### Service-Only Reset

To reset just the application state (keeping infrastructure):

```bash
../reset.sh
```

This stops services, clears observation logs and temporary state, then restarts services.

### Local Docker Reset

```bash
docker compose down -v    # Stops containers and removes volumes
docker compose up -d      # Recreates and starts fresh
```

## DNS Rebind Testing

The DNS rebind test uses a separate process. To manually test:

1. First lookup (should return public IP):
   ```bash
   dig @127.0.0.1 -p 5353 rebind-test.paleon-lab-hostile.com
   ```

2. Second lookup (should return private IP):
   ```bash
   dig @127.0.0.1 -p 5353 rebind-test.paleon-lab-hostile.com
   ```

To reset the rebind state:
```bash
python app/rebind_dns_server.py reset
```

## Security Notes

### Isolation Features

1. **No IAM Role**: The EC2 instance has no attached IAM role or instance profile
2. **Security Group**: 
   - Ingress: HTTP/HTTPS from 0.0.0.0/0, SSH from admin_ip only
   - No explicit egress restrictions (AWS default allows all outbound for updates)
   - No shared security groups with other sites
3. **Network**: 
   - Uses default VPC (no custom VPC, IGW, NAT, etc.)
   - No VPC peering, Transit Gateway, or VPN connections
   - No routing to private networks
4. **Application**:
   - No outbound network calls from Flask app
   - Malformed and DNS servers bind to 127.0.0.1 only
   - No credentials, secrets, or tokens stored
   - No database or external API calls

### What Site 7 Does NOT Do

- ✅ No outbound calls to metadata services (169.254.169.254, 169.254.170.2)
- ✅ No proxying or relaying of requests
- ✅ No credential harvesting or storage
- ✅ No execution of arbitrary code
- ✅ No filesystem access beyond /tmp and /var/lib/site7
- ✅ No network scanning or port scanning
- ✅ No persistent storage of scan data

## Troubleshooting

### Services Not Starting

Check logs:
```bash
journalctl -u paleon-site7 -f
journalctl -u site7-malformed -f
journalctl -u site7-rebind-dns -f
```

### DNS Not Resolving

1. Verify Route53 records:
   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id Z3M3LMPEXAMPLE
   ```

2. Check local DNS resolution:
   ```bash
   dig paleon-lab-hostile.com
   dig offscope.paleon-lab-hostile.com
   dig rebind-test.paleon-lab-hostile.com
   ```

### Application Errors

Check application logs:
```bash
docker compose logs -f flask-app   # Docker
journalctl -u paleon-site7         # Bare metal/EC2
```

### Verification Fails

Run validation first:
```bash
../validate.sh
```

This checks for missing files, syntax errors, and configuration issues before runtime verification.

## Cost Estimates

### Monthly AWS Costs (us-east-1)

- t3.micro EC2: ~$8.50
- Elastic IP: ~$3.60 (if not attached to running instance)
- Route53 hosted zone: $0.50/month + $0.40 per million queries
- Data transfer: Variable based on usage

**Total**: Approximately $12-15/month for light test usage

### Cost Optimization

1. **Stop when not in use**:
   ```bash
   # Stop instance but keep EIP and DNS
   aws ec2 stop-instances --instance-ids i-xxxxxxxxxxxxxxxxx
   
   # Start when needed
   aws ec2 start-instances --instance-ids i-xxxxxxxxxxxxxxxxx
   ```

2. **Use Spot Instances** (modify main.tf):
   ```hcl
   instance_market_options {
     market_type = "spot"
   }
   ```

3. **Destroy when finished**:
   ```bash
   terraform destroy
   ```

## Important Reminders

> ⚠️ **THIS TARGET IS DESIGNED TO ATTEMPT TO INDUCE THE SCANNER TO LEAVE ITS TRUST BOUNDARY.**
> 
> - Do not deploy in any VPC with connectivity to production infrastructure
> - Do not use production AWS accounts or credentials
> - Do not scan with production scanners without proper isolation
> - This target is for VALIDATION ONLY - not for production use
> - Always verify isolation before scanning
> - The reset script is safe to run repeatedly
> - Terraform state contains no secrets - only resource IDs and configuration

## References

- [README.md](./README.md) - Overview and test matrix
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Detailed architecture
- [expected.yaml](./expected.yaml) - Resilience test definitions
- [docs/](./docs/) - Detailed threat model and test specifications