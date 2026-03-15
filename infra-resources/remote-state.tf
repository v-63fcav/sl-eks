# =============================================================================
# REMOTE STATE
# =============================================================================
# Reads infra-cluster outputs directly from S3. This avoids passing complex
# values (lists of subnet IDs, security group IDs) through GitHub Actions
# environment variables, which require careful JSON serialization.
#
# Terraform provider blocks cannot reference data sources, so the three scalar
# values the kubernetes provider needs (cluster_name, kube_host, kube_ca) are
# still passed as TF_VARs. Everything else comes from here.

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "ps-sl-state-bucket-cavi-2"
    key    = "infra-cluster/terraform.tfstate"
    region = "us-east-2"
  }
}
