# =============================================================================
# CUSTOM NETWORKING
# =============================================================================
# ENIConfig CRDs consumed by the VPC CNI on each node at boot time.
# AZ names (data source — known at plan time) are used as for_each keys so
# Terraform can determine the key set before apply. Subnet IDs (module output —
# known only after the VPC is created) are values, which are allowed to be
# (known after apply).

locals {
  az_to_intra_subnet = zipmap(
    slice(data.aws_availability_zones.available.names, 0, 2),
    module.vpc.intra_subnets
  )
}

resource "kubernetes_manifest" "eni_config" {
  for_each = local.az_to_intra_subnet

  manifest = {
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = each.key # AZ name, e.g. "us-east-2a"
    }
    spec = {
      subnet         = each.value # intra subnet ID for this AZ
      securityGroups = [module.eks.node_security_group_id]
    }
  }

  depends_on = [module.eks]
}

# =============================================================================
# STORAGE
# =============================================================================
# Cluster-default StorageClass using the EBS CSI driver. Created in infra so
# it exists before any app PVC can reference it.

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner = "ebs.csi.aws.com"
  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  allow_volume_expansion = true
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"

  depends_on = [module.eks]
}
