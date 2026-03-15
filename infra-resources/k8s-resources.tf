# =============================================================================
# CUSTOM NETWORKING
# =============================================================================
# ENIConfig CRDs consumed by the VPC CNI on each node at boot time.
# AZ names (data source — known at plan time) are used as for_each keys so
# Terraform can determine the key set before apply. Subnet IDs (from infra-cluster
# remote state — known after apply) are values, which are allowed to be
# (known after apply).

data "aws_availability_zones" "available" {}

locals {
  az_to_intra_subnet = zipmap(
    slice(data.aws_availability_zones.available.names, 0, 2),
    data.terraform_remote_state.cluster.outputs.intra_subnets
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
      securityGroups = [data.terraform_remote_state.cluster.outputs.node_security_group_id]
    }
  }
}

# =============================================================================
# STORAGE
# =============================================================================
# Cluster-default StorageClass using the EBS CSI driver. Created here so
# it exists before any app PVC can reference it.
# Uses kubernetes_manifest (server-side apply) so the resource is adopted
# if it already exists — idempotent across re-applies and state migrations.

resource "kubernetes_manifest" "gp3_storage_class" {
  manifest = {
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3"
    }
    provisioner          = "ebs.csi.aws.com"
    allowVolumeExpansion = true
    reclaimPolicy        = "Retain"
    volumeBindingMode    = "WaitForFirstConsumer"
    parameters = {
      type      = "gp3"
      encrypted = "true"
      fsType    = "ext4"
    }
  }
}
