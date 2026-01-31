#ToDo: Create detailed architecture diagram
->VPC
    Public + Private subnets
    NAT Gateway
    Multi-AZ design

->EKS
    Production microservice cluster
    HPA (CPU + custom metrics)
    Cluster Autoscaler

->EC2
    Bastion / jump host
    Worker nodes (or managed node groups)

->ALB
    Ingress for services
    Path-based routing
    TLS termination

->RDS (Postgres)
    Multi-AZ
    Encrypted
    Read replicas (optional)

->IAM
    Least privilege roles
    IRSA for EKS
    Service Control policies (if using org simulation)

->Auto Scaling
    ASG for EC2
    HPA for pods
    Target tracking policies

->CloudWatch
    Custom metrics
    Alarms
    Logs
    Dashboards
    Event-driven remediation