# Two regions, alternate contacts, a customer managed EBS key in one region,
# and VPC Block Public Access for an account with no public-facing workloads.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "ebs_key_arn_us_west_2" {
  type        = string
  description = "Customer managed KMS key for EBS default encryption in us-west-2."
}

module "account_baseline" {
  source = "../.."

  regions = ["us-east-1", "us-west-2"]

  password_policy = {
    minimum_length   = 16
    reuse_prevention = 24
    max_age_days     = 90
  }

  alternate_contact = {
    name  = "Cloud security team"
    email = "aws-security@example.com"
    phone = "+1-555-0100"
  }

  ebs_default_kms_key_arns = {
    "us-west-2" = var.ebs_key_arn_us_west_2
  }

  vpc_block_public_access = "block-bidirectional"
}

output "default_vpc_ids" {
  value = module.account_baseline.default_vpc_ids
}
