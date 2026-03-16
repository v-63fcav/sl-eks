# =============================================================================
# EKS ADDONS
# =============================================================================

# EBS CSI driver — IAM role is in iam.tf; addon depends on the node group so
# the controller pod can be scheduled immediately after the first node is ready.
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.29.1-eksbuild.1"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  depends_on = [aws_eks_node_group.main]
}
