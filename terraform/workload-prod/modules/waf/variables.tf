variable "name" {
  description = "Name prefix for WAF resources"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to associate with WAF"
  type        = string
  default     = ""
}
