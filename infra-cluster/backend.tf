terraform {
  backend "s3" {
    bucket  = "ps-sl-state-bucket-cavi-2"
    key     = "infra-cluster/terraform.tfstate"
    region  = "us-east-2"
    encrypt = true
  }
}
