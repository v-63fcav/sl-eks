# =============================================================================
# CLUSTER
# =============================================================================
# Core EKS control plane. vpc-cni is configured with before_compute = true so
# custom networking is active before any node boots.

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "20.8.4"
  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version
  subnet_ids      = module.vpc.private_subnets

  enable_irsa = true

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  tags = {
    cluster = "ps-sl"
  }

  vpc_id = module.vpc.vpc_id

  # vpc-cni with before_compute = true ensures the addon is applied before any
  # node group is created, so nodes boot with custom networking already active.
  cluster_addons = {
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
          ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
        }
      })
    }
  }
}

# =============================================================================
# ACCESS CONTROL
# =============================================================================
# IAM principals granted cluster-admin via EKS Access Entries (no aws-auth ConfigMap).

resource "aws_eks_access_entry" "admin_access" {
  for_each      = toset(var.eks_admin_principal_arns)
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  type          = "STANDARD"

  depends_on = [module.eks]
}

resource "aws_eks_access_policy_association" "admin_policy" {
  for_each      = toset(var.eks_admin_principal_arns)
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin_access]
}

# =============================================================================
# NODE GROUP
# =============================================================================
# Declared outside module.eks so depends_on = [kubernetes_manifest.eni_config]
# can be expressed explicitly — guaranteeing ENIConfigs exist in every AZ before
# any node boots and the VPC CNI reads them.

resource "aws_launch_template" "node_group" {
  name_prefix            = "${local.cluster_name}-node-"
  vpc_security_group_ids = [module.eks.node_security_group_id, aws_security_group.all_worker_mgmt.id]
}

resource "aws_eks_node_group" "main" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = module.vpc.private_subnets

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

  depends_on = [
    kubernetes_manifest.eni_config,
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# =============================================================================
# ADDONS
# =============================================================================
# EBS CSI Driver — required for dynamic EBS volume provisioning via the gp3 StorageClass.

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.29.1-eksbuild.1"
  service_account_role_arn = aws_iam_role.ebs_csi_driver_role.arn

  depends_on = [module.eks]
}
