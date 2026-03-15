# =============================================================================
# KUBERNETES
# =============================================================================
# Used for any raw Kubernetes manifest resources in this layer.
# Authentication is done via aws eks get-token — no static kubeconfig needed.

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

# =============================================================================
# HELM
# =============================================================================
# Shares the same cluster credentials as the kubernetes provider above.
# All platform tooling and application workloads are deployed via helm_release.

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
