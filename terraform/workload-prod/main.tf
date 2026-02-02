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

# module "rds" {
#   source            = "./modules/rds"
#   name              = var.name
#   vpc_id            = module.vpc.vpc_id
#   db_subnet_ids     = module.vpc.db_subnet_ids
#   db_username       = var.db_username
#   db_password       = var.db_password
# }

# module "waf" {
#   source          = "./modules/waf"
#   name            = var.name
#   alb_arn         = ""  # ALB ARN is known after Ingress deploy; for first pass, attach later
#   # ToDo: Attach WAF to ALB once created by controller by importing or using data sources.
# }