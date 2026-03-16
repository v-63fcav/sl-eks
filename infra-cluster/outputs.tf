output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca" {
  description = "Base64-encoded cluster CA certificate."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the cluster control plane."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID for EKS worker nodes."
  value       = module.eks.node_security_group_id
}

output "node_role_arn" {
  description = "IAM role ARN for worker nodes."
  value       = aws_iam_role.node.arn
}

output "private_subnets" {
  description = "List of private subnet IDs (used by node group)."
  value       = module.vpc.private_subnets
}

output "intra_subnets" {
  description = "List of intra subnet IDs (used by pod ENIConfigs)."
  value       = module.vpc.intra_subnets
}

output "worker_mgmt_sg_id" {
  description = "ID of the additional worker node management security group."
  value       = aws_security_group.all_worker_mgmt.id
}

output "alb_irsa_role" {
  description = "IAM role ARN for the AWS Load Balancer Controller."
  value       = module.alb_irsa_role.iam_role_arn
}

output "oidc_provider" {
  description = "OIDC provider URL (without https://) for constructing IRSA trust policies."
  value       = module.eks.oidc_provider
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for EKS cluster."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID — passed to the ALB controller to avoid IMDS discovery."
  value       = module.vpc.vpc_id
}

output "aws_region" {
  description = "AWS region."
  value       = var.aws_region
}
