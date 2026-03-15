locals {
  ca_ns = "kube-system"
  ca_sa = "cluster-autoscaler"
}

# IAM role for the Cluster Autoscaler pod (IRSA).
# Cluster Autoscaler needs permission to call the EC2 Auto Scaling API
# so it can grow/shrink the node group ASG when pods are unschedulable
# or nodes are underutilised.
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${local.ca_ns}:${local.ca_sa}"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-cluster-autoscaler"
  policy = file("${path.module}/iam-policies/cluster-autoscaler-policy.json")
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# Install Cluster Autoscaler via the official Helm chart.
# The chart creates a Deployment in kube-system that watches for
# Pending pods (scale-up) and underutilised nodes (scale-down).
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = local.ca_ns
  version    = "9.37.0"

  values = [
    yamlencode({
      autoDiscovery = {
        # auto-discovery finds all ASGs tagged with the cluster name,
        # so no manual ASG list is needed.
        clusterName = var.cluster_name
      }
      awsRegion = var.region
      serviceAccount = {
        create = true
        name   = local.ca_sa
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
        }
      }
      # Extra args tell the autoscaler to skip nodes that have system pods
      # (to avoid evicting critical components during scale-down).
      extraArgs = {
        balance-similar-node-groups   = true
        skip-nodes-with-system-pods   = true
        # How long a node must be underutilised before scale-down.
        scale-down-delay-after-add    = "5m"
        scale-down-unneeded-time      = "5m"
      }
    })
  ]

  # Autoscaler must come up after the ALB controller so the cluster is stable.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_autoscaler,
    helm_release.alb_controller,
  ]
}
