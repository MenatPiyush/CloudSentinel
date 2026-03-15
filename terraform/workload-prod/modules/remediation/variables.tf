variable "name" {
  description = "Resource name prefix"
  type        = string
}

variable "node_group_asg_name" {
  description = "EKS managed node group ASG name (used for CloudWatch alarm dimension)"
  type        = string
}

variable "shared_services_lambda_arn" {
  description = "ARN of the remediation Lambda in the Shared Services account"
  type        = string
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization % threshold to trigger remediation alarm"
  type        = number
  default     = 80
}

variable "cpu_alarm_evaluation_periods" {
  description = "Number of evaluation periods before alarm fires"
  type        = number
  default     = 3
}

variable "rds_instance_id" {
  description = "RDS DB instance identifier to monitor for low storage"
  type        = string
  default     = ""  # empty = RDS alarm disabled (e.g. when RDS not deployed)
}

variable "rds_storage_threshold_bytes" {
  description = "Free storage bytes below which the RDS alarm fires (default 5 GB)"
  type        = number
  default     = 5368709120  # 5 * 1024^3
}
