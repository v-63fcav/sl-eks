data "aws_availability_zones" "available" {}

locals {
  cluster_name = "ps-sl-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

# =============================================================================
# VPC
# =============================================================================
# Three-tier network: public (ALBs), private (nodes), intra (pods).
# Custom networking assigns pod IPs from the intra subnets (/19 each, ~8k IPs/AZ)
# instead of the node subnets, separating node and pod address space cleanly.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.7.0"

  name = "ps-sl-eks-vpc"
  cidr = var.vpc_cidr
  # Slice to exactly match subnet count — prevents one_nat_gateway_per_az from
  # trying to place NAT GWs in AZs that have no public subnet
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Node band:  10.0.0.0–10.0.7.255  (/24 per AZ, ~249 node IPs each)
  private_subnets = ["10.0.0.0/24", "10.0.1.0/24"]
  # Public band: 10.0.8.0–10.0.15.255 (/24 per AZ)
  public_subnets = ["10.0.8.0/24", "10.0.9.0/24"]
  # No intra_subnets — pod IPs come from Cilium's overlay CIDR (192.168.0.0/16),
  # not from VPC address space, so a dedicated pod subnet tier is not needed.

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # VPC Flow Logs — captures all traffic metadata for auditing and incident response
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_traffic_type                           = "ALL"
  flow_log_cloudwatch_log_group_retention_in_days = 30

  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

# =============================================================================
# VPC ENDPOINTS
# =============================================================================
# Keep node bootstrapping, ECR pulls, and IRSA token exchange off the NAT
# gateway — reduces cost and keeps traffic within the AWS backbone.

# Dedicated security group for all interface endpoints.
# Allows inbound HTTPS from anywhere within the VPC so nodes, pods, and
# future resources can reach endpoints without additional SG changes.
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "vpc-endpoints-"
  vpc_id      = module.vpc.vpc_id
  description = "Allow HTTPS from within the VPC to interface endpoints"

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

# S3 Gateway endpoint — free; used for ECR layer storage and S3-backed bootstrap
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

# ECR interface endpoints — keeps image pulls within the AWS backbone (cost + security)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

# STS endpoint — keeps IRSA token exchange (AssumeRoleWithWebIdentity) off the NAT GW
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

# EC2 endpoint — vpc-cni calls EC2 APIs to attach secondary ENIs for custom
# networking. Keeping these calls in the AWS backbone avoids NAT GW latency
# and cost during node scale-up events.
resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
