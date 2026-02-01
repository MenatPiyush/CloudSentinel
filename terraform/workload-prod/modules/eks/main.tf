data "aws_caller_identity" "me" {}

resource "aws_iam_role" "eks_cluster_role" {
  name               = "${var.name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_eks_cluster" "this" {
  name = var.name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version = var.cluster_version

  vpc_config {
    subnet_ids = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access = false
    }
    depends_on = [
      aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy
    ]
}

resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node-role"
  assume_role_policy = jsonencode( {
    Version = "2012-10-17",
    Statement = [{
        Effect = "Allow",
        Principal = { Service = "ec2.amazonaws.com"}
        Action = "sts:AssumeRole"
    }]
 })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}
resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_eks_node_group" "mng" {
  cluster_name = aws_eks_cluster.this.name
  node_group_name = "${var.name}-managed-node-group"
  node_role_arn = aws_iam_role.node.arn
  subnet_ids = var.private_subnet_ids

  scaling_config {
    desired_size = 2
    min_size = 2
    max_size = 6
  }

  instance_types = var.node_instance_types
  capacity_type = "ON_DEMAND"

  depends_on = [ 
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy
   ]
}