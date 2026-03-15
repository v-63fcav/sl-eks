# =============================================================================
# ADDONS
# =============================================================================
# Applied after the node group so the addon scheduler can place pods immediately.
# The EBS CSI Driver creates a Deployment — EKS marks the addon unhealthy if
# pods cannot be scheduled, causing terraform apply to hang indefinitely.

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.29.1-eksbuild.1"
  service_account_role_arn = data.terraform_remote_state.cluster.outputs.ebs_csi_driver_role_arn

  depends_on = [aws_eks_node_group.main]
}
