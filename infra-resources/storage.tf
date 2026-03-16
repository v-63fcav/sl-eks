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
