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

# AWS Distro for OpenTelemetry Collector - Replaces Prometheus
resource "helm_release" "adot_collector" {
  name       = "adot-collector"
  repository = "https://aws-observability.github.io/helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.89.0"

  namespace        = "observability"
  create_namespace = true
  cleanup_on_fail  = true

  values = [
    templatefile("${path.module}/values/values-adot.yaml", {
      adot_irsa_role = local.adot_irsa_role
      amp_endpoint   = aws_prometheus_workspace.main.prometheus_endpoint
    })
  ]

  depends_on = [aws_prometheus_workspace.main]
}

# Blackbox Exporter - kept for ADOT integration
resource "helm_release" "blackbox" {
  name       = "blackbox-exporter"
  namespace  = "observability"
  create_namespace = false
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-blackbox-exporter"
  version    = "8.8.0"

  values = [
    file("${path.module}/values/values-blackbox.yaml")
  ]
}