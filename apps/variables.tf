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

variable "adot_irsa_role" {
  type        = string
  description = "IAM role ARN for ADOT collector"
}

variable "amp_endpoint" {
  type        = string
  description = "AMP remote write endpoint"
}
