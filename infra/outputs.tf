output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks.cluster_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane."
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.aws_region
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for EKS cluster"
  value       = module.eks.oidc_provider_arn
}

output "alb_irsa_role" {
  value       = module.alb_irsa_role.iam_role_arn
}

output "intra_subnet_ids" {
  description = "Dedicated pod subnets for EKS custom networking (one per AZ)"
  value       = module.vpc.intra_subnets
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS managed nodes (used in ENIConfig)"
  value       = module.eks.node_security_group_id
}
