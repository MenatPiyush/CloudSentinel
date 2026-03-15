variable "region" {
    type = string
}
variable "name" {
    type = string
}
variable "vpc_cidr" {
    type = string
}
variable "azs" {
    type = list(string)
}
variable "eks_version" { 
    type = string 
}
variable "node_instance_types" {
    type = list(string)
}

variable "shared_services_lambda_arn" {
  description = "ARN of the remediation Lambda in the Shared Services account"
  type        = string
}

variable "shared_services_account_id" {
  description = "AWS account ID of the Shared Services account (for cross-account IAM trust)"
  type        = string
}

# RDS credentials – supply via tfvars or AWS Secrets Manager in CI.
# Never commit actual values to git.
variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "cloudsentinel"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}