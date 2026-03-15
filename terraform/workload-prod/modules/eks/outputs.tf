output "cluster_name" {
    value = aws_eks_cluster.this.name
}
output "cluster_endpoint" {
    value = aws_eks_cluster.this.endpoint
}
output "cluster_ca" {
    value = aws_eks_cluster.this.certificate_authority[0].data
}
output "node_group_asg_name" {
  value = aws_eks_node_group.mng.resources[0].autoscaling_groups[0].name
}