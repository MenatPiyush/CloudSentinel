# ☁️ CloudSentinel V0 — Event-Driven Self-Healing AWS Platform

## 🎯 Overview
CloudSentinel is a central cloud control system that:

- 🚀 Deploys and runs a production app on EKS
- 📈 Automatically scales when traffic increases
- 🩺 Automatically heals when infrastructure fails
- 🛡️ Automatically blocks risky configurations
- ⚡ Automatically reacts to incidents
- 🔁 Enables safe blue/green deployments
- 🧯 Survives failures by design
- 🧩 Operates across multiple AWS accounts

## 🧠 Real-World Scenarios

### 1) 📣 Traffic Spike
**Situation**
Your SaaS app gets mentioned on Product Hunt and traffic jumps 10x.

**Platform Behavior**

- Route53 → ALB → EKS Ingress → Pods
- Pod CPU rises; HPA scales replicas 2 → 10
- Cluster Autoscaler grows node group 2 → 5
- New EC2 nodes launch automatically
- ALB balances across healthy pods

**Outcome:** Seamless scale with no human intervention.

---

### 2) 💥 A Node Dies
**Situation**
An EC2 worker node crashes.

**Platform Behavior**

- Kubernetes marks the node NotReady
- Pods are rescheduled to healthy nodes
- Cluster Autoscaler adds capacity if needed

**Outcome:** Self-healing without downtime.

---

### 3) 🔁 Bad Deployment (Blue/Green)
**Situation**
You deploy v2 and it has a bug.

**Platform Behavior**

- Deploys `governance-api-blue` (stable) and `governance-api-green` (new)
- ALB weighted routing: 90% → Blue, 10% → Green
- Monitor CloudWatch, logs, and error rates
- Shift weights to 100% Blue, 0% Green

**Outcome:** Instant rollback, zero downtime.

---

### 4) 🔐 Security Group Opened to 0.0.0.0/0
**Situation**
A risky SSH rule is accidentally added.

**Platform Behavior**

- CloudWatch detects the risky configuration
- EventBridge triggers a remediation Lambda
- Lambda assumes role, removes the rule, logs to DynamoDB, and sends SNS alert

**Outcome:** Automated governance with audit trail.

---

### 5) 🗄️ RDS Storage Nearly Full
**Situation**
Database storage reaches 90%.

**Platform Behavior**

- CloudWatch alarm fires
- EventBridge triggers Lambda
- Lambda increases RDS storage and logs the action

**Outcome:** Outage avoided proactively.

---

### 6) 🌩️ AZ Failure
**Situation**
`us-east-1a` partially fails.

**Platform Behavior**

- Multi-AZ subnets and nodes keep workloads running
- ALB routes only to healthy targets
- RDS performs automatic failover

**Outcome:** Service remains available.

---

### 7) 🧯 Disaster Recovery
**Situation**
A critical table is dropped.

**Platform Behavior**

- Restore from snapshot / point-in-time
- Update connection string / endpoint
- App reconnects

**Outcome:** Documented RTO/RPO and rapid recovery.

---

### 8) 🧭 Cross-Account Governance
**Situation**
You manage Dev, Stage, and Prod accounts.

**Platform Behavior**

- Central control plane assumes IAM roles in each account
- Remediations and logs are centralized

**Outcome:** Enterprise-grade governance at scale.
