# Look up AZ names from the intra subnet IDs so ENIConfig names match exactly
data "aws_subnet" "intra" {
  for_each = toset(module.vpc.intra_subnets)
  id       = each.value
}

# ENIConfig tells the VPC CNI which subnet and SG to use for pod ENIs in each AZ.
# Names must match AZ names exactly because ENI_CONFIG_LABEL_DEF = topology.kubernetes.io/zone.
# depends_on = [module.eks] ensures the cluster (and CRD) exists before we apply these.
# In practice, node group provisioning takes minutes while Kubernetes API calls take seconds,
# so ENIConfigs always exist before nodes register — matching the EKS Blueprints pattern.
resource "kubernetes_manifest" "eni_config" {
  for_each = { for id in module.vpc.intra_subnets : id => data.aws_subnet.intra[id].availability_zone }

  manifest = {
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = each.value
    }
    spec = {
      subnet         = each.key
      securityGroups = [module.eks.node_security_group_id]
    }
  }

  depends_on = [module.eks]
}

# GP3 StorageClass - cluster-level infrastructure, created before any app PVC can reference it
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner = "kubernetes.io/aws-ebs"
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
