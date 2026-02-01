resource "aws_iam_role" "remediation" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { AWS = var.trusted_principal_arn },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "remediation_policy" {
  name = "${var.role_name}-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid: "ScaleASG",
        Effect: "Allow",
        Action: [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:UpdateAutoScalingGroup",
          "autoscaling:DescribeAutoScalingGroups"
        ],
        Resource: "*"
      },
      {
        Sid: "EC2SecurityGroups",
        Effect: "Allow",
        Action: [
          "ec2:DescribeSecurityGroups",
          "ec2:RevokeSecurityGroupIngress"
        ],
        Resource: "*"
      },
      {
        Sid: "RDS",
        Effect: "Allow",
        Action: [
          "rds:DescribeDBInstances",
          "rds:ModifyDBInstance",
          "rds:CreateDBSnapshot"
        ],
        Resource: "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.remediation.name
  policy_arn = aws_iam_policy.remediation_policy.arn
}
