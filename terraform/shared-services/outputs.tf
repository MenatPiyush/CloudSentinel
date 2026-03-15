output "remediation_lambda_arn" {
  description = "ARN of the central remediation Lambda – pass to workload accounts as shared_services_lambda_arn"
  value       = aws_lambda_function.remediation.arn
}

output "remediation_sns_topic_arn" {
  description = "SNS topic ARN for remediation notifications"
  value       = aws_sns_topic.remediation.arn
}

output "audit_dynamodb_table_name" {
  description = "DynamoDB table name for remediation audit log"
  value       = aws_dynamodb_table.audit.name
}

output "cost_intelligence_lambda_arn" {
  description = "ARN of the cost intelligence Lambda"
  value       = aws_lambda_function.cost_intelligence.arn
}

output "cost_data_dynamodb_table_name" {
  description = "DynamoDB table name for cost intelligence data"
  value       = aws_dynamodb_table.cost_data.name
}
