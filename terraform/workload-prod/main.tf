provider "aws" {
  region = var.region
}

module "vpc" {
  source = "./modules/vpc"
  name = var.name
  cidr = var.vpc_cidr
  azs = var.azs
}

module "eks" {
  source              = "./modules/eks"
  name                = var.name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  cluster_version      = var.eks_version
  node_instance_types  = var.node_instance_types
}

# ─────────────────────────────────────────────
# Controllers – ALB Controller + App Mesh Controller
# Installs both controllers into the EKS cluster via Helm.
# Must run after EKS cluster and node group are ready.
# ─────────────────────────────────────────────
module "controllers" {
  source       = "./modules/controllers"
  region       = var.region
  cluster_name = module.eks.cluster_name
  vpc_id       = module.vpc.vpc_id

  depends_on = [module.eks]
}

module "rds" {
  source = "./modules/rds"

  name                = var.name
  vpc_id              = module.vpc.vpc_id
  db_subnet_ids       = module.vpc.db_subnet_ids
  # Allow only the private subnets CIDR blocks to reach Postgres.
  allowed_cidr_blocks = [var.vpc_cidr]
  db_username         = var.db_username
  db_password         = var.db_password
}

# module "waf" {
#   source          = "./modules/waf"
#   name            = var.name
#   alb_arn         = ""  # ALB ARN is known after Ingress deploy; for first pass, attach later
#   # ToDo: Attach WAF to ALB once created by controller by importing or using data sources.
# }

# ─────────────────────────────────────────────
# Phase 4 – Cross-Account IAM Role
# Allows the Shared Services remediation Lambda to assume this role
# and take remediation actions (scale ASG, revoke SG rules, etc.)
# ─────────────────────────────────────────────
module "cross_account_role" {
  source = "./modules/cross_account_role"

  role_name             = "CloudGovernanceRemediatorRole"
  trusted_principal_arn = "arn:aws:iam::${var.shared_services_account_id}:role/cloudsentinel-remediation-lambda"
}

# ─────────────────────────────────────────────
# Phase 3 + 4 – Observability & Remediation Wiring
# CloudWatch alarms + EventBridge → Shared Services Lambda
# ─────────────────────────────────────────────
module "remediation" {
  source = "./modules/remediation"

  name                       = var.name
  node_group_asg_name        = module.eks.node_group_asg_name
  shared_services_lambda_arn = var.shared_services_lambda_arn
  rds_instance_id            = module.rds.db_instance_id
}