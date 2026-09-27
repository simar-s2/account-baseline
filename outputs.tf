output "regions" {
  description = "Regions the regional settings were applied in."
  value       = sort(tolist(local.regions))
}

output "default_vpc_ids" {
  description = "Default VPC ID per region (null where there is none). Review and delete unused ones with account-baseline.sh --delete-default-vpcs."
  value       = { for r, d in data.aws_vpcs.default : r => try(d.ids[0], null) }
}
