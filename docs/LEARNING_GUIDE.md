# CloudSentinel — Complete Learning Guide

This document walks through every part of the project from first principles.
No assumed AWS knowledge beyond "what is a cloud". By the end you will understand
every file in this repository, every design decision, and how all the pieces
connect to form a production-grade platform.

---

## Table of Contents

1. [What is CloudSentinel?](#1-what-is-cloudsentinel)
2. [Prerequisites & Tools](#2-prerequisites--tools)
3. [Repository Layout](#3-repository-layout)
4. [Concept: Infrastructure as Code with Terraform](#4-concept-infrastructure-as-code-with-terraform)
5. [Layer 1 – Networking (VPC)](#5-layer-1--networking-vpc)
6. [Layer 2 – Compute (EKS)](#6-layer-2--compute-eks)
7. [Layer 3 – Database (RDS)](#7-layer-3--database-rds)
8. [Layer 4 – Traffic & Security (ALB + WAF)](#8-layer-4--traffic--security-alb--waf)
9. [Layer 5 – Kubernetes Controllers (ALB Controller + App Mesh)](#9-layer-5--kubernetes-controllers-alb-controller--app-mesh)
10. [Layer 6 – Application Deployments (Blue/Green)](#10-layer-6--application-deployments-bluegreen)
11. [Layer 7 – Observability (CloudWatch)](#11-layer-7--observability-cloudwatch)
12. [Layer 8 – Auto-Remediation Pipeline](#12-layer-8--auto-remediation-pipeline)
13. [Layer 9 – Multi-Account & Cross-Account IAM](#13-layer-9--multi-account--cross-account-iam)
14. [Layer 10 – Cost Intelligence](#14-layer-10--cost-intelligence)
15. [Layer 11 – CI/CD Pipeline](#15-layer-11--cicd-pipeline)
16. [Layer 12 – Chaos Testing & Disaster Recovery](#16-layer-12--chaos-testing--disaster-recovery)
17. [Key Concept Deep Dives](#17-key-concept-deep-dives)
18. [Deploying the Platform End-to-End](#18-deploying-the-platform-end-to-end)
19. [Verification Checklist](#19-verification-checklist)
20. [Glossary](#20-glossary)

---

## 1. What is CloudSentinel?

Most cloud projects deploy an application and stop there. CloudSentinel is a
**control plane built around an application** — it monitors its own
infrastructure, fixes problems automatically, and enforces governance rules
across multiple AWS accounts.

### The problem it solves

| Pain | How CloudSentinel handles it |
|---|---|
| Engineers wake up at 3am to scale servers | CloudWatch alarm → EventBridge → Lambda scales the ASG automatically |
| A bad deployment breaks production | Blue/green with weighted ALB routing — rollback in seconds |
| Someone opens a security group to `0.0.0.0/0` | Lambda detects and revokes the rule, then writes an audit log |
| Nobody knows what AWS is costing each day | Cost Intelligence Lambda queries Cost Explorer daily and alerts on anomalies |
| Managing multiple AWS accounts is manual | Central Lambda assumes roles into workload accounts; one control plane governs all |

### Architecture in one sentence

> A multi-account AWS platform where a central **Shared Services** account runs
> an event-driven Lambda that automatically remediates infrastructure problems
> detected by CloudWatch in a **Workload** account running a blue/green
> Kubernetes application behind an ALB and App Mesh.

See [ArchitecitureOverview.md](../ArchitecitureOverview.md) for the full diagram.

---

## 2. Prerequisites & Tools

### AWS knowledge you need
- What an IAM role and policy are
- What a VPC, subnet, and security group are
- Basics of EC2 and containers

### Tools to install

```bash
# Terraform (infrastructure provisioning)
brew install terraform           # macOS
# or https://developer.hashicorp.com/terraform/install

# AWS CLI (interact with AWS from terminal)
brew install awscli
aws configure                    # set access key, secret, region

# kubectl (control Kubernetes clusters)
brew install kubectl

# Helm (Kubernetes package manager)
brew install helm

# eksctl (optional — useful for debugging EKS)
brew install eksctl
```

### AWS accounts needed

| Account | Purpose |
|---|---|
| Management | AWS Organizations root, billing only |
| Shared Services | Remediation Lambda, DynamoDB, SNS, EventBridge, Cost Intelligence |
| Workload Prod | VPC, EKS cluster, RDS, ALB, WAF |

> **Tip for learning:** You can run everything in a single AWS account
> to reduce cost. Replace cross-account `sts:AssumeRole` calls with a
> same-account role assumption.

---

## 3. Repository Layout

```
CloudSentinel/
│
├── terraform/
│   ├── bootstrap/              # S3 backend + DynamoDB state lock (run once)
│   ├── org/                    # AWS Organizations — creates the 3 accounts
│   ├── workload-prod/          # Main infrastructure (VPC, EKS, RDS, WAF)
│   │   ├── main.tf             # Wires all modules together
│   │   ├── variables.tf
│   │   └── modules/
│   │       ├── vpc/            # Networking
│   │       ├── eks/            # Kubernetes cluster
│   │       ├── rds/            # PostgreSQL database
│   │       ├── waf/            # Web Application Firewall
│   │       ├── controllers/    # ALB Controller + App Mesh (Helm)
│   │       ├── remediation/    # CloudWatch alarms + EventBridge rules
│   │       └── cross_account_role/  # IAM role Lambda assumes into
│   └── shared-services/        # Central Lambda, DynamoDB audit, SNS, Cost Intelligence
│
├── lambda/
│   ├── remediation/app.py      # Auto-remediation handler (scale ASG, fix SG, etc.)
│   └── cost_intelligence/app.py # Daily Cost Explorer pull + anomaly alert
│
├── k8s/
│   ├── base/                   # Namespace, controller install notes
│   └── apps/
│       ├── governance-api/     # Blue/green Deployments, Services, weighted Ingress
│       └── app-mesh/           # Mesh, VirtualNodes, VirtualRouter, VirtualService
│
├── scripts/
│   ├── chaos/                  # Kill random pod / node to test resilience
│   └── dr/                     # RDS snapshot and restore scripts
│
├── .github/workflows/
│   └── deploy.yaml             # GitHub Actions CI/CD pipeline
│
├── ArchitecitureOverview.md    # Mermaid architecture diagram
└── docs/
    └── LEARNING_GUIDE.md       # This file
```

---

## 4. Concept: Infrastructure as Code with Terraform

### What it is

Instead of clicking through the AWS console, you write `.tf` files that
describe the desired state of your infrastructure. Terraform figures out
what to create, change, or delete to reach that state.

### Key commands

```bash
terraform init      # download providers (AWS, Helm, Kubernetes, TLS)
terraform plan      # show what would change — NEVER modifies anything
terraform apply     # make the changes
terraform destroy   # tear everything down
```

### State file

Terraform stores the current state of your infrastructure in a **state file**
(`terraform.tfstate`). In this project the state is stored remotely in S3 with
a DynamoDB lock table (see `terraform/bootstrap/`) so multiple engineers can
collaborate safely.

### Module pattern

This project uses **modules** — reusable Terraform packages. Each subdirectory
under `modules/` is a self-contained module with its own `variables.tf`,
`main.tf`, and `outputs.tf`. The top-level `main.tf` wires them together:

```hcl
module "eks" {
  source             = "./modules/eks"
  name               = var.name
  vpc_id             = module.vpc.vpc_id      # output from vpc module
  private_subnet_ids = module.vpc.private_subnet_ids
}
```

---

## 5. Layer 1 – Networking (VPC)

**Files:** [terraform/workload-prod/modules/vpc/main.tf](../terraform/workload-prod/modules/vpc/main.tf)

### What gets created

```
VPC  10.0.0.0/16
│
├── Public Subnets (AZ-a, AZ-b)    — ALB, NAT Gateways live here
│     10.0.0.0/20  10.0.16.0/20
│
├── Private App Subnets (AZ-a, AZ-b) — EKS nodes live here (no public IPs)
│     10.0.32.0/20  10.0.48.0/20
│
└── Private DB Subnets (AZ-a, AZ-b)  — RDS lives here
      10.0.64.0/20  10.0.80.0/20
```

### Why three tiers?

**Defence in depth.** Traffic must pass through multiple layers to reach the
database. The internet can only talk to the ALB. The ALB can only talk to
EKS pods. EKS pods can only talk to RDS via a security group rule on port 5432.
The database has no route to the internet.

### Subnet tags for EKS

```hcl
# Public subnets — ALB controller discovers these to place internet-facing ALBs
"kubernetes.io/role/elb" = "1"

# Private subnets — ALB controller discovers these for internal ALBs
"kubernetes.io/role/internal-elb" = "1"
```

Without these tags, the ALB controller cannot find the right subnets and
`Ingress` resources will fail to create a load balancer.

### NAT Gateways

EKS nodes sit in private subnets. They have no public IP. But they need to
pull Docker images from ECR and call AWS APIs. The **NAT Gateway** (one per AZ
for high availability) provides outbound internet access without exposing the
nodes directly.

Cost note: NAT Gateways cost ~$0.045/hour plus $0.045/GB processed. For
learning, one NAT Gateway across both AZs is cheaper (just less resilient).

---

## 6. Layer 2 – Compute (EKS)

**Files:** [terraform/workload-prod/modules/eks/main.tf](../terraform/workload-prod/modules/eks/main.tf)

### What is EKS?

**Elastic Kubernetes Service** — AWS runs the Kubernetes control plane (the
API server, scheduler, etcd) for you. You pay only for the worker nodes
(EC2 instances) that run your actual workloads.

### What gets created

| Resource | Purpose |
|---|---|
| `aws_eks_cluster` | The cluster itself — private endpoint only |
| `aws_iam_role.eks_cluster_role` | EKS control plane identity |
| `aws_eks_node_group` | Managed group of EC2 worker nodes (2–6 instances) |
| `aws_iam_role.node` | EC2 node identity — lets nodes pull images, call CNI |

### IAM roles attached to nodes

```
AmazonEKSWorkerNodePolicy          — allows nodes to call EKS APIs
AmazonEKS_CNI_Policy               — allows the VPC CNI plugin to assign pod IPs
AmazonEC2ContainerRegistryReadOnly — allows nodes to pull images from ECR
```

### Private endpoint only

```hcl
endpoint_private_access = true
endpoint_public_access  = false
```

The Kubernetes API server is not reachable from the internet. CI/CD and
`kubectl` commands must run from within the VPC (or via a bastion/VPN).
This is a deliberate security control.

### Cluster Autoscaler

The node group's `max_size = 6` is the ceiling. The **Cluster Autoscaler**
(a pod running inside EKS) watches for pods that cannot be scheduled due to
insufficient capacity and adds nodes, up to that max.

---

## 7. Layer 3 – Database (RDS)

**Files:** [terraform/workload-prod/modules/rds/main.tf](../terraform/workload-prod/modules/rds/main.tf)

### What gets created

```
aws_db_instance
  engine:            postgres 15
  instance_class:    db.t4g.medium
  allocated_storage: 50 GB
  multi_az:          true          ← automatic failover to standby
  storage_encrypted: true          ← KMS encryption at rest
  publicly_accessible: false       ← only reachable inside the VPC
  backup_retention:  7 days        ← point-in-time recovery
```

### Multi-AZ explained

AWS maintains a **synchronous standby replica** in a second AZ. If the
primary fails, RDS promotes the standby automatically — typically in 60-120
seconds. Your application reconnects to the same endpoint DNS name; the
failover is transparent.

### Security Group

Inbound: port `5432` (PostgreSQL) only from the `allowed_cidr_blocks`
(the private app subnet CIDRs). Nothing else can reach the database.

---

## 8. Layer 4 – Traffic & Security (ALB + WAF)

**Files:** [terraform/workload-prod/modules/waf/main.tf](../terraform/workload-prod/modules/waf/main.tf)

### Traffic flow

```
Internet
  │  HTTPS :443
  ▼
WAFv2 Web ACL
  │  (inspects every request)
  ▼
Application Load Balancer  (public subnets)
  │  forwards to target groups
  ▼
ALB Ingress Controller  (inside EKS)
  │
  ├──► governance-api-blue  (90% of traffic)
  └──► governance-api-green (10% of traffic)
```

### WAF rules applied

1. **AWS Managed Common Rule Set** — blocks OWASP Top 10 attacks (SQLi, XSS, etc.)
2. **Rate limit rule** — blocks any single IP sending > 2000 requests per 5 minutes

### How the ALB is created

The ALB is **not** created by Terraform directly. It is created by the
**AWS Load Balancer Controller** (a Kubernetes operator) when you apply the
`Ingress` resource. The Terraform WAF module just creates the Web ACL; you
associate it with the ALB after it is created via a data source or by importing.

---

## 9. Layer 5 – Kubernetes Controllers (ALB Controller + App Mesh)

**Files:** [terraform/workload-prod/modules/controllers/](../terraform/workload-prod/modules/controllers/)

This layer installs the two main operators into EKS that power traffic management.

### Concept: IRSA (IAM Roles for Service Accounts)

Pods should never have static AWS credentials. **IRSA** lets a Kubernetes
ServiceAccount assume an IAM role. Here is how it works:

```
1. EKS cluster has an OIDC provider (a JWT-issuing endpoint)
2. A Terraform aws_iam_role is created with a trust policy that says:
   "Only tokens from THIS cluster + THIS namespace/serviceaccount can assume me"
3. The ServiceAccount gets an annotation: eks.amazonaws.com/role-arn = <arn>
4. When a pod starts, the EKS pod identity webhook injects a projected
   volume with a short-lived JWT token
5. The AWS SDK in the pod exchanges that token for temporary credentials
   via the STS AssumeRoleWithWebIdentity API
```

No secrets, no rotation needed.

### OIDC Provider setup

```hcl
# isra-oidc.tf
resource "aws_iam_openid_connect_provider" "eks" {
  url            = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}
```

The `thumbprint_list` is a TLS fingerprint AWS uses to verify the token is
genuinely from your cluster's OIDC endpoint.

### Trust policy structure for IRSA

```json
{
  "Condition": {
    "StringEquals": {
      "<oidc-issuer>:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
      "<oidc-issuer>:aud": "sts.amazonaws.com"
    }
  }
}
```

The `sub` claim pins the trust to one specific ServiceAccount. A pod in a
different namespace or using a different ServiceAccount cannot assume this role.

### ALB Controller

Installed via Helm (`aws-load-balancer-controller` chart from `aws.github.io/eks-charts`).

What it does: watches for `Ingress` resources in Kubernetes. When one is
created, it calls the AWS ELB APIs to create an ALB, target groups, listener
rules, and registers pods as targets. When you delete the Ingress, it cleans up
all the AWS resources.

IAM permissions it needs: ~200 lines of EC2 + ELB + WAF + ACM permissions
stored in [iam-policies/alb-controller-policy.json](../terraform/workload-prod/modules/controllers/iam-policies/alb-controller-policy.json).

### App Mesh Controller

Installed via Helm (`appmesh-controller` chart).

What it does: watches for App Mesh custom resources (`Mesh`, `VirtualNode`,
`VirtualService`, `VirtualRouter`). When found, it injects an **Envoy proxy**
sidecar into your pods and programs the proxy with the correct routing rules.

Why use a service mesh?
- Traffic routing (e.g. retry policies, timeouts) is handled by the proxy, not your code
- Mutual TLS between services without application changes
- Detailed traffic metrics per service pair

---

## 10. Layer 6 – Application Deployments (Blue/Green)

**Files:** [k8s/apps/governance-api/](../k8s/apps/governance-api/), [k8s/apps/app-mesh/](../k8s/apps/app-mesh/)

### Blue/Green explained

Two identical deployments run simultaneously:

| Colour | Role | Traffic |
|---|---|---|
| Blue | Stable / current production | 90% |
| Green | New version / canary | 10% |

When you deploy a new version you always update **green**. You observe its
behaviour (error rate, latency) in CloudWatch. If it looks good, you shift
traffic to 100% green. If something is wrong, you shift back to 100% blue.
No downtime in either direction.

### How weighted routing is implemented

The `Ingress` resource uses an ALB **forward action annotation** rather than
standard Kubernetes routing:

```yaml
# ingress-weighted.yaml
alb.ingress.kubernetes.io/actions.governance-forward: >
  {"type":"forward","forwardConfig":{"targetGroups":[
    {"serviceName":"governance-api-blue",  "servicePort":"80","weight":90},
    {"serviceName":"governance-api-green", "servicePort":"80","weight":10}
  ]}}
```

The ALB controller translates this annotation into an ALB listener rule with
two weighted target groups. Traffic splitting happens at the load balancer
layer — pods have no knowledge of it.

Note: `ingressClassName: alb` (spec field) is preferred over the deprecated
`kubernetes.io/ingress.class: alb` annotation in ALB Controller v2.3+.

### App Mesh resources

```
Mesh "governance-mesh"
  └── VirtualService "governance-api"
        └── VirtualRouter "governance-api-router"
              ├── VirtualNode "governance-api-blue"   (DNS: governance-api-blue.governance.svc.cluster.local)
              └── VirtualNode "governance-api-green"  (DNS: governance-api-green.governance.svc.cluster.local)
```

The Envoy sidecar in each pod intercepts all inbound/outbound traffic and
enforces the routing rules defined in these custom resources.

---

## 11. Layer 7 – Observability (CloudWatch)

**Files:** [terraform/workload-prod/modules/remediation/main.tf](../terraform/workload-prod/modules/remediation/main.tf)

### Three pillars

| Pillar | Tool | What it captures |
|---|---|---|
| Logs | CloudWatch Logs | Container stdout/stderr, ALB access logs, RDS logs |
| Metrics | CloudWatch Metrics | CPU, memory, request count, DB connections, custom metrics |
| Alarms | CloudWatch Alarms | Threshold breaches that trigger the remediation pipeline |

### Key alarms

| Alarm | Condition | Action |
|---|---|---|
| `high-cpu-<asg-name>` | EC2 CPU > 90% for 10 minutes | EventBridge → Lambda → scale ASG |
| `high-memory-*` | Node memory pressure | EventBridge → Lambda → scale ASG |

### Why the alarm name prefix matters

The EventBridge rule in `shared-services` matches alarms by name prefix:

```json
"alarmName": [{ "prefix": "high-cpu-" }]
```

Any CloudWatch alarm whose name starts with `high-cpu-` will trigger the
remediation Lambda. This is how you add new workload accounts without
changing the central EventBridge rule — just name your alarms correctly.

---

## 12. Layer 8 – Auto-Remediation Pipeline

**Files:** [lambda/remediation/app.py](../lambda/remediation/app.py), [terraform/shared-services/main.tf](../terraform/shared-services/main.tf)

### End-to-end flow

```
[EKS node CPU > 90% for 10 min]
        │
        ▼
CloudWatch Alarm → state: ALARM
        │
        ▼
EventBridge Rule (workload account)
  pattern: source=aws.cloudwatch, alarmName prefix=high-cpu-
        │
        ▼
EventBridge → cross-account → Remediation Lambda (shared services account)
  input_transformer injects: { account_id, action, asg_name, desired }
        │
        ▼
Lambda: assume(account_id)
  → sts:AssumeRole → CloudGovernanceRemediatorRole (workload account)
        │
        ├── autoscaling:UpdateAutoScalingGroup(desired=3)
        │
        ├── dynamodb:PutItem → audit record
        │     pk = "ACCOUNT#<id>"
        │     sk = "2026-03-14T06:00:00Z"  ← composite key prevents duplicates
        │
        └── sns:Publish → email alert
```

### Why cross-account Lambda?

The Lambda lives in **Shared Services**. It has IAM permission to assume
`CloudGovernanceRemediatorRole` in any listed workload account. Each workload
account grants only the minimum permissions that role needs (ASG scaling,
SG modification, RDS modification).

This is the exact pattern large enterprises use. A single control plane
governs 10s or 100s of accounts without duplicating Lambda code everywhere.

### DynamoDB schema

```
Table: cloudsentinel-remediation-audit
  pk (String) = "ACCOUNT#123456789012"     ← partition key
  sk (String) = "2026-03-14T06:00:00Z"     ← sort key (ISO timestamp)
  action      = "scale_asg"
  payload     = JSON string of the full event
  status      = "SUCCESS" | "FAILED"
  error       = error message (only on FAILED)
  expires_at  = Unix epoch + 90 days        ← TTL auto-deletes old records
```

Using `pk + sk` as a composite key means multiple remediations for the same
account are all stored and queryable. Without `sk`, a second remediation for
the same account would overwrite the first.

### Lambda code walkthrough

```python
# 1. Read account_id and action from the EventBridge event
account_id = event.get('account_id')
action     = event.get('action')

# 2. Assume the role in the target account
session = assume(account_id)   # returns a boto3.Session with temp credentials

# 3. Dispatch to the correct remediation handler
if action == "scale_asg":
    handle_high_cpu_scale_asg(session, event["asg_name"], int(event["desired"]))

# 4. Audit + notify regardless of outcome (try/except wraps everything)
log_event(audit_info)
notify(subject, audit_info)
```

---

## 13. Layer 9 – Multi-Account & Cross-Account IAM

**Files:** [terraform/org/](../terraform/org/), [terraform/workload-prod/modules/cross_account_role/main.tf](../terraform/workload-prod/modules/cross_account_role/main.tf)

### AWS Organizations

The `terraform/org/` module creates an AWS Organization and provisions three
member accounts (Security, Shared Services, Workload Prod) using
`aws_organizations_account`. The management account pays for all.

### Cross-account role assumption

```
Shared Services account
  └── Lambda execution role
        └── Permission: sts:AssumeRole → arn:aws:iam::<workload-id>:role/CloudGovernanceRemediatorRole

Workload Prod account
  └── CloudGovernanceRemediatorRole
        └── Trust policy: "Principal": { "AWS": "<shared-services-lambda-role-arn>" }
        └── Permissions:
              autoscaling:UpdateAutoScalingGroup
              ec2:RevokeSecurityGroupIngress
              rds:ModifyDBInstance
```

Step by step:
1. Lambda calls `sts:AssumeRole` with the workload account role ARN
2. STS validates the trust policy — is the Lambda's role ARN in the `Principal`?
3. STS returns temporary credentials (AccessKey, SecretKey, SessionToken)
4. Lambda creates a new `boto3.Session` with those credentials
5. All subsequent API calls go to the **workload account** as the remediation role

### Service Control Policies (future)

The `terraform/org/` skeleton sets up the structure for SCPs — account-level
IAM guardrails that even account admins cannot override. Examples:

```json
// Deny disabling CloudTrail
{ "Effect": "Deny", "Action": "cloudtrail:StopLogging", "Resource": "*" }

// Deny public S3 buckets
{ "Effect": "Deny", "Action": "s3:PutBucketPublicAccessBlock",
  "Condition": { "StringEquals": { "s3:PublicAccessBlockConfiguration": "false" } } }
```

---

## 14. Layer 10 – Cost Intelligence

**Files:** [lambda/cost_intelligence/app.py](../lambda/cost_intelligence/app.py), [terraform/shared-services/main.tf](../terraform/shared-services/main.tf)

### What it does

An EventBridge **scheduled rule** triggers the Cost Intelligence Lambda once
daily at 06:00 UTC. The Lambda:

1. Calls `ce.get_cost_and_usage()` — yesterday's spend grouped by AWS service
2. Filters by `LINKED_ACCOUNT_IDS` if set (to aggregate across workload accounts)
3. Stores the result in DynamoDB (`pk = "COST#2026-03-13"`)
4. If total spend exceeds `COST_ALERT_THRESHOLD` (default $50/day), publishes to SNS

### Cost Explorer API

```python
response = ce.get_cost_and_usage(
    TimePeriod  = {"Start": "2026-03-13", "End": "2026-03-14"},
    Granularity = "DAILY",
    Metrics     = ["UnblendedCost"],
    GroupBy     = [{"Type": "DIMENSION", "Key": "SERVICE"}],
)
# response["ResultsByTime"][0]["Groups"] → list of {Keys: [service], Metrics: {UnblendedCost: {...}}}
```

### Alert format

```
Subject: [CloudSentinel] Daily spend $87.42 exceeds threshold
Body:
  CloudSentinel Cost Alert
  Date: 2026-03-13
  Total: $87.42 USD  (threshold: $50.00)

  Top 5 services:
    Amazon Elastic Kubernetes Service: $31.20
    Amazon RDS: $18.40
    Amazon EC2-Other (NAT): $14.90
    Amazon EC2: $12.80
    AWS Lambda: $0.03
```

### DynamoDB schema

```
Table: cloudsentinel-cost-data
  pk         = "COST#2026-03-13"
  ts         = "2026-03-13"
  total_usd  = "87.4200"
  by_service = JSON string { "Amazon EKS": "31.2000", ... }
  expires_at = TTL (auto-delete after 90 days)
```

---

## 15. Layer 11 – CI/CD Pipeline

**File:** [.github/workflows/deploy.yaml](../.github/workflows/deploy.yaml)

### Three jobs

```
push to main
    │
    ├── Job 1: build-push
    │     Configure AWS (OIDC, no stored secrets)
    │     docker build  → tag: "green-<git-sha>"
    │     docker push   → ECR
    │     outputs: image_tag, ecr_image
    │
    ├── Job 2: terraform (needs: build-push)
    │     terraform init + validate + plan
    │     On PR:  post plan output as PR comment
    │     On main: terraform apply
    │
    └── Job 3: deploy-k8s (needs: build-push, terraform)
          kubectl apply k8s/base/
          kubectl set image deployment/governance-api-green → new image
          kubectl apply k8s/apps/governance-api/
          kubectl apply k8s/apps/app-mesh/
          kubectl rollout status deployment/governance-api-green --timeout=5m
```

### OIDC — no stored AWS secrets

Traditional CI/CD stores `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as
GitHub secrets. These are long-lived credentials that can be leaked.

**OIDC** replaces this: GitHub generates a short-lived JWT for each workflow
run. AWS is configured to trust GitHub's OIDC provider. The workflow exchanges
the JWT for temporary STS credentials via `aws-actions/configure-aws-credentials`.

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_PROD_DEPLOY_ROLE_ARN }}
    aws-region: us-east-1
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are now set automatically
# They expire when the job ends
```

### PR safety

```
pull_request → main:  plan only, no apply, plan posted as PR comment
push → main:          plan + apply + deploy
```

Reviewers see exactly what Terraform will change before approving.

### Blue/green strategy in CI

CI always deploys to **green**. Blue is untouched. This means:
- Every merge to main updates only the green Deployment
- Blue continues serving 90% of traffic while green is tested at 10%
- Traffic shift (green to 100%) is a manual step — change the weights in
  `ingress-weighted.yaml` and re-apply

---

## 16. Layer 12 – Chaos Testing & Disaster Recovery

**Files:** [scripts/chaos/](../scripts/chaos/), [scripts/dr/](../scripts/dr/)

### Chaos testing

```bash
# Kill a random pod in the governance namespace
scripts/chaos/delete_random_pod.sh governance

# What this tests:
# → Kubernetes reschedules the pod (self-healing)
# → HPA still shows correct replica count
# → ALB continues routing to healthy pods (target health check)
```

```bash
# Drain a random worker node
scripts/chaos/kill_random_node.sh

# What this tests:
# → Pods are evicted and rescheduled on remaining nodes
# → Cluster Autoscaler adds a new node to replace it
# → Multi-AZ means the other AZ absorbs the traffic
```

### Disaster Recovery — RDS

```bash
# Take a manual snapshot
python3 scripts/dr/snapshot_rds.py
# Creates: cloudsentinel-pg-manual-2026-03-14T06-00-00

# Restore to a new instance from a snapshot
python3 scripts/dr/restore_rds.py
# Creates: cloudsentinel-pg-restored (Multi-AZ, encrypted)
# You then update the application's DB_HOST environment variable
```

**RTO** (Recovery Time Objective): ~20-30 minutes to restore + app reconnect
**RPO** (Recovery Point Objective): up to 24 hours (or seconds with PITR)

Point-in-time recovery (PITR) is available because `backup_retention_period = 7`.
You can restore to any second within the last 7 days.

---

## 17. Key Concept Deep Dives

### IRSA vs Instance Profile

| | Instance Profile | IRSA |
|---|---|---|
| Granularity | All pods on a node share the role | Per ServiceAccount |
| Blast radius | Any pod can call any AWS API the node role permits | Pod is limited to its own role |
| Credential rotation | Automatic (every 6 hours) | Automatic (every 15 minutes) |
| Auditing | CloudTrail shows node role | CloudTrail shows serviceaccount name |

**Always use IRSA in EKS.**

### EventBridge event pattern matching

EventBridge does **content-based filtering** — you describe the shape of the
event you want to match. This is more efficient than Lambda polling because
events that don't match are discarded before your Lambda is even invoked.

```json
{
  "source":       ["aws.cloudwatch"],
  "detail-type":  ["CloudWatch Alarm State Change"],
  "detail": {
    "state":      { "value": ["ALARM"] },
    "alarmName":  [{ "prefix": "high-cpu-" }]
  }
}
```

The `prefix` operator is powerful — it lets you add new alarms (`high-cpu-web`,
`high-cpu-api`, `high-cpu-worker`) without changing the EventBridge rule.

### Terraform `for_each` vs `count`

```hcl
# count — creates N identical copies, indexed 0,1,2...
resource "aws_nat_gateway" "nat" {
  count = 2
}
# Problem: if you remove index 0, index 1 becomes 0 — Terraform destroys and recreates it

# for_each — creates one copy per map/set key, keyed by the key string
resource "aws_nat_gateway" "nat" {
  for_each = aws_subnet.public    # keyed by AZ name: "us-east-1a", "us-east-1b"
}
# Removing "us-east-1a" only removes that one resource — "us-east-1b" is unchanged
```

This project uses `for_each` throughout to avoid accidental deletions.

### Kubernetes Deployment vs Service vs Ingress

```
Internet
  │
Ingress (Layer 7 routing rules — ALB annotations)
  │  routes /api → service "governance-api-blue" (weight 90%)
  │  routes /api → service "governance-api-green" (weight 10%)
  │
Service (stable DNS + load balancing inside the cluster)
  │  governance-api-blue.governance.svc.cluster.local
  │  → selects pods with label color=blue
  │
Deployment (manages pods)
  │  governance-api-blue
  │  spec.replicas: 2
  └─► Pod, Pod  (label: color=blue)
```

A `Deployment` manages the lifecycle of pods.
A `Service` gives them a stable internal DNS name and load balances across them.
An `Ingress` routes external traffic to different services based on rules.

---

## 18. Deploying the Platform End-to-End

Follow these steps in order. Each step builds on the previous.

### Step 0 — Bootstrap (once per AWS account)

```bash
cd terraform/bootstrap
terraform init && terraform apply
# Creates: S3 bucket for state, DynamoDB lock table
```

### Step 1 — AWS Organizations (optional for single-account learning)

```bash
cd terraform/org
terraform init && terraform apply
# Creates: AWS Organization, Security account, Shared Services account, Workload Prod account
```

### Step 2 — Workload infrastructure

```bash
cd terraform/workload-prod
terraform init
terraform apply \
  -var="region=us-east-1" \
  -var="name=cloudsentinel" \
  -var="vpc_cidr=10.0.0.0/16" \
  -var='azs=["us-east-1a","us-east-1b"]' \
  -var="eks_version=1.30" \
  -var='node_instance_types=["t3.medium"]'
# Creates: VPC, EKS, IAM roles
```

### Step 3 — Connect kubectl to EKS

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name cloudsentinel
kubectl get nodes   # should show 2 nodes in Ready state
```

### Step 4 — Install Kubernetes controllers

```bash
cd terraform/workload-prod/modules/controllers
terraform init && terraform apply \
  -var="region=us-east-1" \
  -var="cluster_name=cloudsentinel" \
  -var="vpc_id=<your-vpc-id>"

# Verify
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get deployment -n appmesh-system appmesh-controller
```

### Step 5 — Apply Kubernetes manifests

```bash
# Base (namespace must exist first)
kubectl apply -f k8s/base/namespace.yaml

# App Mesh resources (Mesh CRDs must exist before VirtualNodes)
kubectl apply -f k8s/apps/app-mesh/mesh.yaml
kubectl apply -f k8s/apps/app-mesh/virtual-nodes.yaml
kubectl apply -f k8s/apps/app-mesh/virtual-router.yaml
kubectl apply -f k8s/apps/app-mesh/virtual-service.yaml

# Application
kubectl apply -f k8s/apps/governance-api/
kubectl get ingress -n governance   # wait for ADDRESS to be populated
```

### Step 6 — Deploy shared services (Lambda + EventBridge)

```bash
cd terraform/shared-services
terraform init
terraform apply \
  -var='workload_account_ids=["<your-workload-account-id>"]' \
  -var="alarm_notification_email=you@example.com" \
  -var="cost_alert_threshold_usd=50"
```

### Step 7 — Verify remediation end-to-end

```bash
# Manually trigger the CloudWatch alarm into ALARM state
aws cloudwatch set-alarm-state \
  --alarm-name "high-cpu-<your-asg-name>" \
  --state-value ALARM \
  --state-reason "manual test"

# Check Lambda was invoked
aws logs tail /aws/lambda/cloudsentinel-remediation --follow

# Check DynamoDB audit record
aws dynamodb query \
  --table-name cloudsentinel-remediation-audit \
  --key-condition-expression "pk = :pk" \
  --expression-attribute-values '{":pk":{"S":"ACCOUNT#<your-account-id>"}}'
```

---

## 19. Verification Checklist

Use this to confirm each layer is working after deployment.

- [ ] **VPC**: `aws ec2 describe-vpcs --filters Name=tag:Name,Values=cloudsentinel`
- [ ] **EKS nodes**: `kubectl get nodes -o wide` — 2 nodes, `Ready`, private IPs
- [ ] **ALB Controller**: `kubectl get deployment -n kube-system aws-load-balancer-controller`
- [ ] **App Mesh Controller**: `kubectl get deployment -n appmesh-system appmesh-controller`
- [ ] **Blue pods running**: `kubectl get pods -n governance -l color=blue`
- [ ] **Green pods running**: `kubectl get pods -n governance -l color=green`
- [ ] **Ingress created ALB**: `kubectl get ingress -n governance` — ADDRESS column populated
- [ ] **WAF attached to ALB**: AWS Console → WAF → Web ACLs → verify association
- [ ] **Lambda deployed**: `aws lambda get-function --function-name cloudsentinel-remediation`
- [ ] **DynamoDB tables exist**: `aws dynamodb list-tables`
- [ ] **EventBridge rule active**: `aws events list-rules --name-prefix cloudsentinel`
- [ ] **Cost Lambda scheduled**: `aws events describe-rule --name cloudsentinel-cost-daily`
- [ ] **End-to-end remediation**: trigger alarm manually, check DynamoDB + email

---

## 20. Glossary

| Term | Meaning |
|---|---|
| **ALB** | Application Load Balancer — Layer 7 HTTP/HTTPS load balancer |
| **ASG** | Auto Scaling Group — a fleet of EC2 instances that scales automatically |
| **CRD** | Custom Resource Definition — extends Kubernetes with new resource types |
| **DynamoDB** | AWS serverless key-value / document database |
| **ECR** | Elastic Container Registry — AWS Docker image registry |
| **EKS** | Elastic Kubernetes Service — managed Kubernetes on AWS |
| **EventBridge** | AWS event bus — routes events between services and accounts |
| **HPA** | Horizontal Pod Autoscaler — scales pod replicas based on CPU/custom metrics |
| **IRSA** | IAM Roles for Service Accounts — pod-level AWS credentials via OIDC |
| **KMS** | Key Management Service — managed encryption keys |
| **Managed Node Group** | EKS worker nodes managed by AWS (AMI updates, draining) |
| **NAT Gateway** | Allows private subnet resources to reach the internet outbound only |
| **OIDC** | OpenID Connect — identity federation protocol used by IRSA and GitHub Actions |
| **RDS** | Relational Database Service — managed PostgreSQL/MySQL/etc. |
| **SNS** | Simple Notification Service — pub/sub messaging (email, SMS, Lambda, SQS) |
| **STS** | Security Token Service — issues temporary AWS credentials |
| **Terraform** | HashiCorp tool for declarative infrastructure provisioning |
| **VirtualNode** | App Mesh resource representing a logical service endpoint |
| **VirtualRouter** | App Mesh resource that holds weighted routing rules |
| **VirtualService** | App Mesh resource that is the stable DNS name clients talk to |
| **VPC** | Virtual Private Cloud — isolated network in AWS |
| **WAFv2** | Web Application Firewall v2 — HTTP-level traffic filtering |
