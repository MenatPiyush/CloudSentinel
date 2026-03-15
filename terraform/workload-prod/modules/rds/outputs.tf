output "db_instance_id" {
  description = "RDS instance identifier – used by CloudWatch alarm and Lambda remediation"
  value       = aws_db_instance.this.identifier
}

output "db_endpoint" {
  description = "RDS instance connection endpoint"
  value       = aws_db_instance.this.endpoint
}
