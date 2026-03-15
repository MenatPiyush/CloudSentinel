provider "aws" {
  region = var.region
}

# ─────────────────────────────────────────────
# DynamoDB – Remediation Audit Log
# ─────────────────────────────────────────────
resource "aws_dynamodb_table" "audit" {
  name         = "${var.name}-remediation-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "ts"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# ─────────────────────────────────────────────
# SNS – Remediation Notifications
# ─────────────────────────────────────────────
resource "aws_sns_topic" "remediation" {
  name = "${var.name}-remediation"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.remediation.arn
  protocol  = "email"
  endpoint  = var.alarm_notification_email
}

# ─────────────────────────────────────────────
# Lambda – Remediation Function
# ─────────────────────────────────────────────
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.root}/../../lambda/remediation"
  output_path = "${path.module}/lambda-remediation.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}-remediation-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "lambda" {
  name = "${var.name}-remediation-lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "AssumeWorkloadRoles"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          for id in var.workload_account_ids :
          "arn:aws:iam::${id}:role/CloudGovernanceRemediatorRole"
        ]
      },
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.audit.arn
      },
      {
        Sid      = "SNS"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.remediation.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

resource "aws_lambda_function" "remediation" {
  function_name    = "${var.name}-remediation"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "app.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda.arn
  timeout          = 60

  environment {
    variables = {
      ASSUME_ROLE_NAME = "CloudGovernanceRemediatorRole"
      DDB_TABLE_NAME   = aws_dynamodb_table.audit.name
      SNS_TOPIC_ARN    = aws_sns_topic.remediation.arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.remediation.function_name}"
  retention_in_days = 30
}

# ─────────────────────────────────────────────
# EventBridge – CloudWatch Alarm → Lambda
# ─────────────────────────────────────────────

# Rule: any CloudWatch alarm prefixed "high-cpu-" enters ALARM state
resource "aws_cloudwatch_event_rule" "high_cpu" {
  name        = "${var.name}-high-cpu-alarm"
  description = "Triggers remediation Lambda when a high-CPU alarm fires"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      state     = { value = ["ALARM"] }
      alarmName = [{ prefix = "high-cpu-" }]
    }
  })
}

resource "aws_cloudwatch_event_target" "high_cpu" {
  rule = aws_cloudwatch_event_rule.high_cpu.name
  arn  = aws_lambda_function.remediation.arn

  # Pass a structured input so the Lambda knows what to do
  input_transformer {
    input_paths = {
      account   = "$.account"
      alarmName = "$.detail.alarmName"
    }
    input_template = <<-EOT
      {
        "account_id": "<account>",
        "action":     "scale_asg",
        "asg_name":   "<alarmName>",
        "desired":    3
      }
    EOT
  }
}

resource "aws_lambda_permission" "eventbridge_high_cpu" {
  statement_id  = "AllowEventBridgeHighCPU"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.high_cpu.arn
}

# Allow workload account EventBridge rules to invoke the remediation Lambda
# cross-account.  Add one permission per workload account.
resource "aws_lambda_permission" "allow_workload_eventbridge" {
  for_each = toset(var.workload_account_ids)

  statement_id  = "AllowWorkloadEventBridge-${each.value}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  # source_arn scoped to the workload account so no other account can invoke
  source_arn = "arn:aws:events:${var.region}:${each.value}:rule/*"
}

# ─────────────────────────────────────────────
# Phase 5 – Cost Intelligence
# ─────────────────────────────────────────────

# DynamoDB table to store daily cost snapshots
resource "aws_dynamodb_table" "cost_data" {
  name         = "${var.name}-cost-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "ts"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# IAM role for Cost Intelligence Lambda
resource "aws_iam_role" "cost_lambda" {
  name = "${var.name}-cost-intelligence-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "cost_lambda" {
  name = "${var.name}-cost-intelligence-lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logging"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "CostExplorer"
        Effect = "Allow"
        Action = ["ce:GetCostAndUsage", "ce:GetCostForecast"]
        Resource = "*"
      },
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.cost_data.arn
      },
      {
        Sid      = "SNS"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.remediation.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cost_lambda" {
  role       = aws_iam_role.cost_lambda.name
  policy_arn = aws_iam_policy.cost_lambda.arn
}

data "archive_file" "cost_lambda" {
  type        = "zip"
  source_dir  = "${path.root}/../../lambda/cost_intelligence"
  output_path = "${path.module}/lambda-cost-intelligence.zip"
}

resource "aws_lambda_function" "cost_intelligence" {
  function_name    = "${var.name}-cost-intelligence"
  filename         = data.archive_file.cost_lambda.output_path
  source_code_hash = data.archive_file.cost_lambda.output_base64sha256
  handler          = "app.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.cost_lambda.arn
  timeout          = 60

  environment {
    variables = {
      COST_TABLE_NAME      = aws_dynamodb_table.cost_data.name
      SNS_TOPIC_ARN        = aws_sns_topic.remediation.arn
      COST_ALERT_THRESHOLD = tostring(var.cost_alert_threshold_usd)
      LINKED_ACCOUNT_IDS   = join(",", var.workload_account_ids)
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cost_lambda]
}

resource "aws_cloudwatch_log_group" "cost_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.cost_intelligence.function_name}"
  retention_in_days = 30
}

# EventBridge scheduled rule – run cost collection once per day at 06:00 UTC
resource "aws_cloudwatch_event_rule" "cost_daily" {
  name                = "${var.name}-cost-daily"
  description         = "Trigger cost intelligence Lambda daily at 06:00 UTC"
  schedule_expression = "cron(0 6 * * ? *)"
}

resource "aws_cloudwatch_event_target" "cost_daily" {
  rule = aws_cloudwatch_event_rule.cost_daily.name
  arn  = aws_lambda_function.cost_intelligence.arn
}

resource "aws_lambda_permission" "eventbridge_cost_daily" {
  statement_id  = "AllowEventBridgeCostDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_intelligence.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost_daily.arn
}
