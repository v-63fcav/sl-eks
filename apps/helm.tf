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

# resource "helm_release" "prometheus_stack" {
#   name       = "prometheus-stack"
#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "kube-prometheus-stack"
#   version    = "47.6.1"

#   namespace        = "prometheus-stack"
#   create_namespace = true
#   cleanup_on_fail  = true

#   values = [
#     "${file("${path.module}/values/values-prometheus.yaml")}"
#   ]

#   depends_on = [
#     kubernetes_storage_class_v1.gp3
#   ]
# }

# resource "helm_release" "blackbox" {
#   name       = "blackbox-exporter"
#   namespace  = "monitoring"
#   create_namespace = true
#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "prometheus-blackbox-exporter"
#   version    = "8.8.0"

#   values = [
#     file("${path.module}/values/values-blackbox.yaml")
#   ]
# }

# resource "helm_release" "metrics_server" {
#   name       = "metrics-server"
#   repository = "https://kubernetes-sigs.github.io/metrics-server"
#   chart      = "metrics-server"
#   version    = "3.12.2"

#   namespace  = "kube-system"
  
#   values = [
#     file("${path.module}/values/values-metrics-server.yaml")
#   ]
# }

# # Sample application with gp3 volume mount
# resource "helm_release" "sample_app" {
#   name       = "sample-app"
#   namespace  = "default"
#   create_namespace = false

#   chart = "${path.module}/sample-app-chart"
  
#   timeout = 600
#   atomic  = true

#   values = [
#     file("${path.module}/sample-app-chart/values.yaml")
#   ]

#   depends_on = [
#     kubernetes_storage_class_v1.gp3
#   ]
# }
