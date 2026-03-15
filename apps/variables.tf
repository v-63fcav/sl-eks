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
