# Amazon Managed Grafana Workspace
data "aws_caller_identity" "current" {}

resource "aws_grafana_workspace" "main" {
  name              = "eks-study-grafana"
  account_access_type = "CURRENT_ACCOUNT"
  
  data_sources {
    prometheus {
      name               = "amp"
      prometheus_endpoint = aws_prometheus_workspace.main.prometheus_endpoint
      workspace_id       = aws_prometheus_workspace.main.id
    }
  }

  role_arn = aws_iam_role.amg_role.arn

  tags = {
    Environment = "eks-study"
    ManagedBy   = "terraform"
    Project     = "eks-study"
  }
}

# IAM role for AMG workspace
resource "aws_iam_role" "amg_role" {
  name = "amg-role-eks-study"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "grafana.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Environment = "eks-study"
    ManagedBy   = "terraform"
  }
}

# Attach AMP permissions to AMG role
resource "aws_iam_role_policy_attachment" "amg_amp_access" {
  role       = aws_iam_role.amg_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

# Allow admin access from EKS admin principal
resource "aws_iam_role_policy_attachment" "amg_admin_access" {
  role       = aws_iam_role.amg_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonGrafanaAdminFullAccess"
}

# Output AMP and AMG URLs
output "amp_endpoint" {
  description = "AMP remote write endpoint for ADOT collector"
  value       = aws_prometheus_workspace.main.prometheus_endpoint
}

output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.main.id
}

output "amg_workspace_id" {
  description = "AMG workspace ID"
  value       = aws_grafana_workspace.main.id
}

output "amg_workspace_url" {
  description = "AMG workspace URL"
  value       = aws_grafana_workspace.main.workspace_endpoint
}
