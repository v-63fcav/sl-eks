variable "aws_region" {
  default     = "us-east-2"
  description = "AWS region"
}

variable "cluster_name" {
  type        = string
  default     = ""
  description = "description"
}

variable "kube_host" {}
variable "kube_ca" {}
variable "alb_irsa_role" {}

variable "intra_subnet_ids" {
  type        = list(string)
  description = "Dedicated pod subnet IDs for EKS custom networking ENIConfig (one per AZ, from infra outputs)"
}

variable "node_security_group_id" {
  type        = string
  description = "Security group ID attached to EKS managed nodes, applied to pod ENIs via ENIConfig"
}
