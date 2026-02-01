provider "aws" {
  region = var.region
}

resource "aws_organizations_organization" "org" {
  feature_set = var.org_feature_set
}

resource "aws_organizations_account" "security" {
  name  = var.security_account_name
  email = var.security_email
}

resource "aws_organizations_account" "shared" {
  name  = var.shared_account_name
  email = var.shared_email
}

resource "aws_organizations_account" "prod" {
  name  = var.prod_account_name
  email = var.prod_email
}