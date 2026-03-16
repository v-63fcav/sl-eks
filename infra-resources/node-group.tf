# =============================================================================
# NODE GROUP
# =============================================================================
# Managed node group with AL2023 + t3.medium. Launch template is used only to
# attach the correct security groups — AMI, instance type, and userData are
# managed by EKS. Reads networking and IAM values from infra-cluster remote state.

resource "aws_launch_template" "node_group" {
  name_prefix = "${var.cluster_name}-node-"
  vpc_security_group_ids = [
    data.terraform_remote_state.cluster.outputs.node_security_group_id,
    data.terraform_remote_state.cluster.outputs.worker_mgmt_sg_id,
  ]
}

resource "aws_eks_node_group" "main" {
  cluster_name    = var.cluster_name
  node_group_name = "node-group"
  node_role_arn   = data.terraform_remote_state.cluster.outputs.node_role_arn
  subnet_ids      = data.terraform_remote_state.cluster.outputs.private_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["t3.medium"]

  scaling_config {
    min_size     = 2
    max_size     = 6
    desired_size = 2
  }

  launch_template {
    id      = aws_launch_template.node_group.id
    version = aws_launch_template.node_group.latest_version
  }

}
