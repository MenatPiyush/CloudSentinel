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