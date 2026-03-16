data "aws_availability_zones" "available" {}

locals {
  cluster_name = "sl-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

# =============================================================================
# VPC
# =============================================================================
# Two-tier network: public (ALBs, NAT GWs) and private (nodes + pods).
# Standard vpc-cni with prefix delegation — no custom networking, no overlay.
#
# Layout (10.0.0.0/16):
#   Public band  10.0.0.0/19   — one /24 per AZ, room for 6 AZs
#   Private band 10.0.32.0/19+ — one /19 per AZ, sequential by 32 in 3rd octet
#     active : 10.0.32.0/19  10.0.64.0/19  10.0.96.0/19
#     future : 10.0.128.0/19 10.0.160.0/19 10.0.192.0/19

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.7.0"

  name = "sl-eks-vpc"
  cidr = var.vpc_cidr
  # Slice to exactly match subnet count — prevents one_nat_gateway_per_az from
  # trying to place NAT GWs in AZs that have no public subnet
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Private band: /19 per AZ — nodes and pods share the subnet via prefix delegation.
  # Each /19 holds 512 × /28 prefixes; reserving the first /20 (below) keeps
  # prefix blocks contiguous and avoids InsufficientCidrBlocks errors.
  private_subnets = ["10.0.32.0/19", "10.0.64.0/19", "10.0.96.0/19"]
  # Public band: /24 per AZ — sized for NAT GWs and ALB nodes (AWS recommendation).
  public_subnets = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]

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
# SUBNET CIDR RESERVATIONS — prefix delegation
# =============================================================================
# Reserves the first /20 of each private /19 exclusively for /28 prefix blocks.
# Without this, individual secondary IPs can fragment the address space over time,
# causing EC2 to fail prefix allocation with InsufficientCidrBlocks errors.

locals {
  # First /20 of each private /19 (cidrsubnet splits the /19 in half, index 0 = first half)
  private_prefix_reservation_cidrs = [
    for cidr in ["10.0.32.0/19", "10.0.64.0/19", "10.0.96.0/19"] :
    cidrsubnet(cidr, 1, 0)
  ]
}

resource "aws_ec2_subnet_cidr_reservation" "prefix_delegation" {
  count            = length(local.private_prefix_reservation_cidrs)
  subnet_id        = module.vpc.private_subnets[count.index]
  cidr_block       = local.private_prefix_reservation_cidrs[count.index]
  reservation_type = "prefix"
  description      = "Reserved for vpc-cni /28 prefix delegation blocks"
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

# EC2 endpoint — vpc-cni calls EC2 APIs to assign /28 prefix blocks to ENIs
# during node scale-up. Keeping these calls in the AWS backbone avoids NAT GW
# latency and cost.
resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
