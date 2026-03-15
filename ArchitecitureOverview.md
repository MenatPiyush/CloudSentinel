# CloudSentinel – Architecture Overview

An event-driven AWS governance and auto-remediation platform spanning multiple accounts.
All infrastructure is Terraform-managed. Deployments are blue/green with weighted ALB routing.

---

## Multi-Account Structure

```
AWS Organizations (Management Account)
│
├── Security Account          ← GuardDuty admin, CloudTrail aggregation (planned)
├── Shared Services Account   ← Remediation Lambda, DynamoDB audit, SNS, EventBridge
└── Workload Prod Account     ← VPC, EKS, RDS, WAF, ALB, App Mesh
```

---

## Full Architecture Diagram

```mermaid
flowchart TB

  %% ── USERS / EDGE ──────────────────────────────────────────────
  USER([Users / Admins])
  USER -->|HTTPS| WAF

  subgraph EDGE["Edge"]
    WAF["AWS WAFv2\n(Rate limit · Managed rules)"]
    ALB["Application Load Balancer\n(internet-facing · TLS 443)"]
    WAF --> ALB
  end

  %% ── VPC ───────────────────────────────────────────────────────
  subgraph VPC["AWS VPC  ·  Multi-AZ (us-east-1a / 1b)"]
    direction TB

    subgraph PUB["Public Subnets"]
      IGW["Internet Gateway"]
      NAT["NAT Gateways\n(one per AZ)"]
    end

    subgraph PRIVAPP["Private App Subnets"]
      direction TB
      INGRESS["AWS Load Balancer\nController (IRSA)"]

      subgraph EKS["EKS Cluster  ·  Managed Node Groups (ASG 2-6)"]
        direction LR
        BLUE["governance-api\n── blue (90%)"]
        GREEN["governance-api\n── green (10%)"]
        MESH["App Mesh sidecar\n(Envoy)"]
      end

      CA["Cluster Autoscaler"]
      HPA["HPA\n(CPU-based)"]
    end

    subgraph PRIVDB["Private DB Subnets"]
      RDS[("RDS PostgreSQL 15\nMulti-AZ · Encrypted\ndb.t4g.medium")]
    end
  end

  ALB -->|"Weighted forward\n90 / 10"| INGRESS
  INGRESS --> BLUE
  INGRESS --> GREEN
  BLUE ---|App Mesh| MESH
  GREEN ---|App Mesh| MESH
  BLUE -->|SQL| RDS
  GREEN -->|SQL| RDS
  IGW --> NAT --> PRIVAPP

  %% ── OBSERVABILITY ─────────────────────────────────────────────
  subgraph OBS["Observability  (Workload Account)"]
    CWL["CloudWatch Logs\n(EKS · ALB · RDS)"]
    CWM["CloudWatch Metrics\n+ Custom Metrics"]
    DASH["CloudWatch\nDashboards"]
    ALARM["CloudWatch Alarms\nhigh-cpu-* · storage · SG"]
    CWL --> DASH
    CWM --> ALARM
  end

  EKS -->|container logs| CWL
  ALB -->|access logs| CWL
  RDS -->|performance insights| CWL

  %% ── AUTO-REMEDIATION PIPELINE ─────────────────────────────────
  subgraph SHARED["Shared Services Account"]
    direction TB
    EB["EventBridge Rule\nAlarm → ALARM state"]
    LAMBDA["Remediation Lambda\nPython 3.12"]
    DDB[("DynamoDB\nAudit Log\npk=ACCOUNT# · sk=ts")]
    SNS["SNS Topic\n→ Email / Slack"]

    EB --> LAMBDA
    LAMBDA --> DDB
    LAMBDA --> SNS
  end

  ALARM -->|state change event| EB
  LAMBDA -->|sts:AssumeRole\nCloudGovernanceRemediatorRole| WORKLOAD_ROLE

  subgraph CROSS["Cross-Account IAM  (Workload Prod)"]
    WORKLOAD_ROLE["CloudGovernanceRemediatorRole\n(ASG · EC2 · RDS · SGs)"]
    WORKLOAD_ROLE -->|scale up| ASG_TARGET["Auto Scaling Group\n(EKS node group)"]
    WORKLOAD_ROLE -->|revoke rule| SG_TARGET["Security Groups"]
    WORKLOAD_ROLE -->|modify| RDS_TARGET["RDS Instance"]
  end

  %% ── CI/CD ─────────────────────────────────────────────────────
  subgraph CICD["CI/CD  (GitHub Actions · OIDC)"]
    GH["GitHub Push"]
    BUILD["Build & Push\nDocker → ECR"]
    DEPLOY["kubectl apply\nblue/green manifests"]
    GH --> BUILD --> DEPLOY
  end

  DEPLOY -->|update Deployment| EKS

  %% ── SECURITY ──────────────────────────────────────────────────
  subgraph SEC["Security Controls"]
    IAM["IAM\nLeast-privilege · IRSA"]
    KMS["KMS\n(RDS · S3)"]
    CT["CloudTrail\n(API audit)"]
    VPCFL["VPC Flow Logs"]
  end

  %% ── DISASTER RECOVERY ─────────────────────────────────────────
  subgraph DR["Disaster Recovery"]
    SNAP["RDS Snapshot\n(scripts/dr/snapshot_rds.py)"]
    RESTORE["RDS Restore\n(scripts/dr/restore_rds.py)"]
    SNAP --> RESTORE
  end

  RDS -.->|scheduled snapshot| SNAP

  %% ── CHAOS TESTING ─────────────────────────────────────────────
  subgraph CHAOS["Chaos Testing  (scripts/chaos/)"]
    KILLPOD["delete_random_pod.sh\n→ test pod recovery"]
    KILLNODE["kill_random_node.sh\n→ test node autoscaling"]
  end

  EKS -.->|target| KILLPOD
  EKS -.->|target| KILLNODE

  %% ── STYLES ────────────────────────────────────────────────────
  classDef aws       fill:#f0f4ff,stroke:#5a7fcf,stroke-width:1.5px,color:#1a1a2e
  classDef shared    fill:#fff7e6,stroke:#d4a017,stroke-width:1.5px,color:#3a2a00
  classDef security  fill:#f0fff4,stroke:#2e8b57,stroke-width:1.5px,color:#1a3a1a
  classDef edge      fill:#fdf0ff,stroke:#9b59b6,stroke-width:1.5px,color:#2a0a3a
  classDef neutral   fill:#f9f9f9,stroke:#aaa,stroke-width:1px,color:#333

  class WAF,ALB edge
  class EKS,RDS,CWL,CWM,DASH,ALARM,CA,HPA,INGRESS,IGW,NAT aws
  class EB,LAMBDA,DDB,SNS shared
  class IAM,KMS,CT,VPCFL security
  class SNAP,RESTORE,KILLPOD,KILLNODE neutral
```

---

## Remediation Flow (Step by Step)

```
EKS Node CPU > 90% (10 min)
  │
  ▼
CloudWatch Metric Alarm  →  state: ALARM
  │
  ▼
EventBridge Rule  (source: aws.cloudwatch, alarmName prefix: high-cpu-)
  │
  ▼
Remediation Lambda  (Shared Services account)
  │   ├── sts:AssumeRole  →  CloudGovernanceRemediatorRole  (Workload account)
  │   ├── autoscaling:UpdateAutoScalingGroup  (desired += N)
  │   ├── DynamoDB PutItem  (audit record: pk=ACCOUNT#<id>, sk=<ts>)
  │   └── SNS Publish  (email notification)
  │
  ▼
Auto Scaling Group scales up  →  CloudWatch alarm recovers  →  OK state
```

---

## Blue / Green Deployment Flow

```
New image pushed to ECR
  │
  ▼
GitHub Actions  →  kubectl set image deployment/governance-api-green
  │
  ▼
ALB Weighted Target Groups
  ├── Blue  (stable)  ──  90% traffic
  └── Green (canary)  ──  10% traffic
  │
  ▼
Validate metrics in CloudWatch
  │
  ├── Healthy  →  shift to 100% green, retire blue
  └── Issues   →  shift back to 100% blue (rollback)
```

---

## Key Design Decisions

| Decision | Choice | Why |
|---|---|---|
| Ingress | AWS ALB Controller (IRSA) | Native integration with WAF + ACM, weighted routing |
| Service mesh | App Mesh (Envoy sidecar) | AWS-native, no separate control plane cost |
| Deployments | Blue/Green via weighted ALB | Zero-downtime, instant rollback |
| Remediation | Cross-account Lambda via STS | Central control plane, least-privilege per account |
| Audit log | DynamoDB (pk + sk) | Serverless, per-account query by pk, TTL for cost |
| Secrets | IRSA everywhere | No long-lived credentials in pods or Lambda |
| IaC | Terraform modules | Reusable, state-tracked, PR-reviewable |
