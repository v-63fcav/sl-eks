# =============================================================================
# AWS
# =============================================================================

provider "aws" {
  region = var.aws_region
}

# =============================================================================
# KUBERNETES
# =============================================================================
# Credentials come from infra-cluster outputs passed as TF_VARs by the CI.
# By the time this job runs, the cluster, access entries, and IAM roles
# already exist in AWS — eliminating the Unauthorized error that occurred
# when these resources were created in the same apply as the kubernetes provider.

provider "kubernetes" {
  host                   = var.kube_host
  cluster_ca_certificate = base64decode(var.kube_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      var.cluster_name
    ]
  }
}
