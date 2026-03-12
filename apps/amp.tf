# Amazon Managed Prometheus Workspace
resource "aws_prometheus_workspace" "main" {
  alias = "eks-study-prometheus"
  logging_configuration {
    default_log_group {
      retention_in_days = 7
    }
  }
  tags = {
    Environment = "eks-study"
    ManagedBy   = "terraform"
    Project     = "eks-study"
  }
}