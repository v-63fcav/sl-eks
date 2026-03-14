resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/values/values-alb-controller.yaml", {
      cluster_name  = var.cluster_name
      alb_irsa_role = var.alb_irsa_role
    })
  ]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "69.3.1"
  namespace        = "monitoring"
  create_namespace = true

  values = [file("${path.module}/values/values-kube-prometheus-stack.yaml")]

  # CRDs can be large; increase timeout for first install
  timeout = 600

  depends_on = [kubernetes_storage_class_v1.gp3]
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.29.0"
  namespace  = "monitoring"

  values = [file("${path.module}/values/values-loki.yaml")]

  depends_on = [kubernetes_storage_class_v1.gp3, helm_release.kube_prometheus_stack]
}

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.14.0"
  namespace  = "monitoring"

  values = [file("${path.module}/values/values-tempo.yaml")]

  depends_on = [kubernetes_storage_class_v1.gp3, helm_release.kube_prometheus_stack]
}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = "monitoring"

  set = [
    {
      name  = "config.clients[0].url"
      value = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
    }
  ]

  depends_on = [helm_release.loki]
}

resource "helm_release" "opentelemetry_collector" {
  name       = "opentelemetry-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.118.0"
  namespace  = "monitoring"

  values = [file("${path.module}/values/values-otel-collector.yaml")]

  depends_on = [helm_release.loki, helm_release.tempo, helm_release.kube_prometheus_stack]
}

resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  values = [file("${path.module}/values/values-otel-operator.yaml")]

  depends_on = [helm_release.opentelemetry_collector]
}

# The operator registers its CRDs asynchronously after the Helm release completes.
# Wait for the webhook and CRDs to be fully ready before applying the Instrumentation CR.
resource "time_sleep" "otel_operator_ready" {
  create_duration = "30s"
  depends_on      = [helm_release.otel_operator]
}

resource "helm_release" "node_ws" {
  name      = "node-ws"
  chart     = "${path.module}/app-chart"
  namespace = "default"

  depends_on = [time_sleep.otel_operator_ready]
}

resource "helm_release" "otel_test_app" {
  name      = "otel-test-app"
  chart     = "${path.module}/otel-test-app-chart"
  namespace = "default"

  depends_on = [helm_release.opentelemetry_collector]
}