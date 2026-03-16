# =============================================================================
# OUTPUTS
# =============================================================================
# Pass-through values consumed by the apps layer CI job.
# Sourced from input vars (which came from infra-cluster outputs) and remote state.

output "cluster_name" {
  value = var.cluster_name
}

output "cluster_endpoint" {
  value = var.kube_host
}

output "cluster_ca" {
  value = var.kube_ca
}

output "alb_irsa_role" {
  value = data.terraform_remote_state.cluster.outputs.alb_irsa_role
}

output "vpc_id" {
  value = data.terraform_remote_state.cluster.outputs.vpc_id
}
