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
# These are applied in the same job as the cluster so they exist before
# infra-resources attempts to authenticate with the kubernetes provider.

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

