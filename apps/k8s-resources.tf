# Look up AZ names from the intra subnet IDs so ENIConfig names match exactly
data "aws_subnet" "intra" {
  for_each = toset(var.intra_subnet_ids)
  id       = each.value
}

# ENIConfig tells the VPC CNI which subnet and SG to use for pod ENIs in each AZ.
# Names must match AZ names exactly because ENI_CONFIG_LABEL_DEF = topology.kubernetes.io/zone.
resource "kubernetes_manifest" "eni_config" {
  for_each = { for id in var.intra_subnet_ids : id => data.aws_subnet.intra[id].availability_zone }

  manifest = {
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = each.value
    }
    spec = {
      subnet         = each.key
      securityGroups = [var.node_security_group_id]
    }
  }
}

# GP3 StorageClass with recommended configurations using in-tree EBS provider
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner = "kubernetes.io/aws-ebs"
  parameters = {
    type       = "gp3"
    encrypted  = "true"
    fsType     = "ext4"
  }

  allow_volume_expansion = true
  reclaim_policy         = "Retain"
  volume_binding_mode   = "WaitForFirstConsumer"
}
