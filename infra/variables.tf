variable "kubernetes_version" {
  default     = 1.34
  description = "Kubernetes version"
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "Default CIDR range of the VPC"
}

variable "aws_region" {
  default     = "us-east-2"
  description = "AWS region"
}

variable "eks_admin_principal_arns" {
  type        = list(string)
  default     = [
    "arn:aws:iam::659934583510:user/Felipe_Cavichiolli",
    "arn:aws:iam::659934583510:root"
  ]
  description = "List of IAM principal ARNs to grant EKS cluster admin access (e.g., arn:aws:iam::123456789012:user/username, arn:aws:iam::123456789012:root)"
}
