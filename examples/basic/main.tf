# Applies the baseline in the provider's region with the default settings.

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

module "account_baseline" {
  source = "../.."
}

output "default_vpc_ids" {
  value = module.account_baseline.default_vpc_ids
}
