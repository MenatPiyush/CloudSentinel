locals {
  mesh_ns = "appmesh-system"
  mesh_sa = "appmesh-controller"
}

# IAM role for App Mesh Controller ServiceAccount (IRSA)
resource "aws_iam_role" "appmesh_controller" {
  name = "${var.cluster_name}-appmesh-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${local.mesh_ns}:${local.mesh_sa}"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "appmesh_controller" {
  role       = aws_iam_role.appmesh_controller.name
  policy_arn = "arn:aws:iam::aws:policy/AWSAppMeshFullAccess"
}

resource "aws_iam_role_policy_attachment" "appmesh_controller_xray" {
  role       = aws_iam_role.appmesh_controller.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Install App Mesh Controller via Helm
resource "helm_release" "appmesh_controller" {
  name       = "appmesh-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "appmesh-controller"
  namespace  = local.mesh_ns
  version    = "1.13.1"

  create_namespace = true

  values = [
    yamlencode({
      region = var.region
      serviceAccount = {
        create = true
        name   = local.mesh_sa
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.appmesh_controller.arn
        }
      }
      tracing = {
        enabled  = false
        provider = "x-ray"
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.appmesh_controller,
    helm_release.alb_controller,
  ]
}
