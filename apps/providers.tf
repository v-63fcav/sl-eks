# =============================================================================
# HELM
# =============================================================================
# All platform tooling and application workloads are deployed via helm_release.
# Cluster credentials are passed as TF_VARs from the infra-resources CI job.

provider "helm" {
  kubernetes = {
    host                   = var.kube_host
    cluster_ca_certificate = base64decode(var.kube_ca)

    exec = {
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
}
