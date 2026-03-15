variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Resource name prefix"
  type        = string
  default     = "cloudsentinel"
}

variable "workload_account_ids" {
  description = "List of workload account IDs the Lambda can assume role into"
  type        = list(string)
}

variable "alarm_notification_email" {
  description = "Email address for SNS remediation notifications"
  type        = string
}

variable "cost_alert_threshold_usd" {
  description = "Daily spend threshold in USD that triggers a cost anomaly alert"
  type        = number
  default     = 50
}
