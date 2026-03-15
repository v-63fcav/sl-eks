# Only the three values required to configure the kubernetes provider block.
# All other infra-cluster outputs are read via the remote state data source.

variable "aws_region" {
  default     = "us-east-2"
  description = "AWS region"
}

variable "cluster_name" {
  description = "EKS cluster name (passed from infra-cluster CI job output)"
}

variable "kube_host" {
  description = "EKS cluster API endpoint (passed from infra-cluster CI job output)"
}

variable "kube_ca" {
  description = "EKS cluster CA certificate, base64-encoded (passed from infra-cluster CI job output)"
}
