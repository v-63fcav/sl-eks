# =============================================================================
# AWS
# =============================================================================
# Pure AWS layer — no kubernetes provider needed here.
# EKS control plane, VPC, IAM, and security groups are all AWS resources.

provider "aws" {
  region = var.aws_region
}
