data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ─────────────────────────────────────────────
# Phase 3 – CloudWatch Alarms
# ─────────────────────────────────────────────

# Alarm name uses the "high-cpu-" prefix so the Shared Services
# EventBridge rule (pattern: alarmName prefix = "high-cpu-") fires.
# The alarm name is also passed as asg_name via the EventBridge
# input_transformer in shared-services, so we name it after the ASG.
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "high-cpu-${var.node_group_asg_name}"
  alarm_description   = "EKS node group average CPU > ${var.cpu_alarm_threshold}% for ${var.cpu_alarm_evaluation_periods} consecutive periods"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = var.cpu_alarm_evaluation_periods
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.node_group_asg_name
  }
}

# High memory alarm (requires CloudWatch agent / Container Insights on nodes)
resource "aws_cloudwatch_metric_alarm" "high_memory" {
  alarm_name          = "${var.name}-node-high-memory"
  alarm_description   = "EKS node group average memory utilization > 80%"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.node_group_asg_name
  }
}

# ─────────────────────────────────────────────
# Phase 3 – CloudWatch Dashboard
# ─────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name}-governance"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node CPU Utilization"
          view   = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.node_group_asg_name,
              { stat = "Average", period = 300, label = "CPU Avg %" }]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = var.cpu_alarm_threshold, label = "Alarm threshold", color = "#ff6961" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node Memory Utilization"
          view   = "timeSeries"
          stacked = false
          metrics = [
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", var.node_group_asg_name,
              { stat = "Average", period = 300, label = "Memory Avg %" }]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 80, label = "Alarm threshold", color = "#ff6961" }]
          }
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 6
        width  = 24
        height = 4
        properties = {
          title = "Active Alarms"
          alarms = concat(
            [
              aws_cloudwatch_metric_alarm.high_cpu.arn,
              aws_cloudwatch_metric_alarm.high_memory.arn,
            ],
            var.rds_instance_id != "" ? [aws_cloudwatch_metric_alarm.rds_low_storage[0].arn] : []
          )
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────
# Phase 4 – EventBridge → Shared Services Lambda
#
# CloudWatch alarm state changes are emitted to the local (workload)
# account EventBridge default bus.  We forward the high-cpu alarm event
# directly to the Shared Services remediation Lambda cross-account.
# ─────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "high_cpu_forward" {
  name        = "${var.name}-high-cpu-forward"
  description = "Forward high-CPU alarm state changes to Shared Services remediation Lambda"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      state     = { value = ["ALARM"] }
      alarmName = [{ prefix = "high-cpu-" }]
    }
  })
}

resource "aws_cloudwatch_event_target" "high_cpu_lambda" {
  rule = aws_cloudwatch_event_rule.high_cpu_forward.name
  arn  = var.shared_services_lambda_arn

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

# Allow this account's EventBridge to invoke the cross-account Lambda
resource "aws_lambda_permission" "allow_workload_eventbridge" {
  statement_id  = "AllowWorkloadEventBridge-${data.aws_caller_identity.current.account_id}"
  action        = "lambda:InvokeFunction"
  function_name = var.shared_services_lambda_arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.high_cpu_forward.arn
}

# ─────────────────────────────────────────────
# Scenario 4 – Open Security Group Detection
#
# CloudTrail records every EC2 API call and publishes it to the default
# EventBridge bus. We match on AuthorizeSecurityGroupIngress so the Lambda
# can inspect the rule and remove it if it's open to 0.0.0.0/0.
# ─────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "open_sg" {
  name        = "${var.name}-open-sg-detect"
  description = "Detect when an ingress rule open to 0.0.0.0/0 is added to any security group"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AuthorizeSecurityGroupIngress"]
    }
  })
}

resource "aws_cloudwatch_event_target" "open_sg_lambda" {
  rule = aws_cloudwatch_event_rule.open_sg.name
  arn  = var.shared_services_lambda_arn

  # Extract the SG ID and the full ipPermissions list from the CloudTrail event.
  # The Lambda filters down to only open-internet rules before revoking.
  input_transformer {
    input_paths = {
      account        = "$.account"
      groupId        = "$.detail.requestParameters.groupId"
      ipPermissions  = "$.detail.requestParameters.ipPermissions"
    }
    input_template = <<-EOT
      {
        "account_id":     "<account>",
        "action":         "remove_open_sg",
        "group_id":       "<groupId>",
        "ip_permissions": <ipPermissions>
      }
    EOT
  }
}

resource "aws_lambda_permission" "allow_open_sg_eventbridge" {
  statement_id  = "AllowOpenSGEventBridge-${data.aws_caller_identity.current.account_id}"
  action        = "lambda:InvokeFunction"
  function_name = var.shared_services_lambda_arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.open_sg.arn
}

# ─────────────────────────────────────────────
# Scenario 5 – RDS Storage Nearly Full
#
# CloudWatch alarm on FreeStorageSpace. When free space drops below
# the threshold, EventBridge invokes the Lambda to expand storage.
# The alarm is only created when rds_instance_id is provided.
# ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  count = var.rds_instance_id != "" ? 1 : 0

  alarm_name          = "${var.name}-rds-low-storage"
  alarm_description   = "RDS free storage below ${var.rds_storage_threshold_bytes / 1073741824} GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.rds_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }
}

resource "aws_cloudwatch_event_rule" "rds_low_storage" {
  count = var.rds_instance_id != "" ? 1 : 0

  name        = "${var.name}-rds-low-storage"
  description = "Trigger storage expansion when RDS free space alarm fires"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      state     = { value = ["ALARM"] }
      alarmName = ["${var.name}-rds-low-storage"]
    }
  })
}

resource "aws_cloudwatch_event_target" "rds_low_storage_lambda" {
  count = var.rds_instance_id != "" ? 1 : 0

  rule = aws_cloudwatch_event_rule.rds_low_storage[0].name
  arn  = var.shared_services_lambda_arn

  input_transformer {
    input_paths = {
      account = "$.account"
    }
    input_template = <<-EOT
      {
        "account_id":              "<account>",
        "action":                  "increase_rds_storage",
        "db_instance_identifier":  "${var.rds_instance_id}",
        "increment_gb":            20
      }
    EOT
  }
}

resource "aws_lambda_permission" "allow_rds_storage_eventbridge" {
  count = var.rds_instance_id != "" ? 1 : 0

  statement_id  = "AllowRDSStorageEventBridge-${data.aws_caller_identity.current.account_id}"
  action        = "lambda:InvokeFunction"
  function_name = var.shared_services_lambda_arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rds_low_storage[0].arn
}
