locals {
  alb_ns = "kube-system"
  alb_sa = "aws-load-balancer-controller"
  oidc = aws_iam_openid_connect_provider.eks.url
  oidc_arn = aws_iam_openid_connect_provider.eks.arn
}

