provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "ps-sl-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.7.0"

  name                 = "ps-sl-eks-vpc"
  cidr                 = var.vpc_cidr
  azs                  = data.aws_availability_zones.available.names
  # Node band:   10.0.0.0–10.0.7.255   (/24 per AZ, 8 AZ slots, ~249 IPs each)
  # With custom networking nodes use 1 IP each (primary ENI only); /24 supports ~249 nodes/AZ
  private_subnets = ["10.0.0.0/24", "10.0.1.0/24"]
  # Public band:  10.0.8.0–10.0.15.255  (/24 per AZ, 8 AZ slots)
  public_subnets  = ["10.0.8.0/24", "10.0.9.0/24"]
  # Pod band:     10.0.16.0–10.0.239.255 (/19 per AZ, 7 AZ slots, ~8k IPs each)
  # 10.0.240.0–10.0.255.255 reserved — fits one /20 as an 8th pod AZ at half density
  intra_subnets   = ["10.0.16.0/19", "10.0.48.0/19"]
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

# S3 Gateway endpoint — free, keeps node bootstrapping and ECR layer pulls off the NAT GW
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids)
}

# ECR interface endpoints — keeps image pulls within the AWS backbone (cost + security)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [module.vpc.default_security_group_id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [module.vpc.default_security_group_id]
  private_dns_enabled = true
}

# STS endpoint — keeps IRSA token exchange (AssumeRoleWithWebIdentity) off the NAT GW
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [module.vpc.default_security_group_id]
  private_dns_enabled = true
}
