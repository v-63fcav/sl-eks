resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/values/values-alb-controller.yaml", {
      cluster_name = var.cluster_name
      alb_irsa_role = var.alb_irsa_role
    })
  ]
}

resource "helm_release" "prometheus_stack" {
  name       = "prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "47.6.1"

  namespace        = "prometheus-stack"
  create_namespace = true

  values = [
    "${file("${path.module}/values/values-prometheus.yaml")}"
  ]
}

resource "helm_release" "blackbox" {
  name       = "blackbox-exporter"
  namespace  = "monitoring"
  create_namespace = true
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-blackbox-exporter"
  version    = "8.8.0"

  values = [
    file("${path.module}/values/values-blackbox.yaml")
  ]
}