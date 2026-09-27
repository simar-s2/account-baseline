data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  regions = toset(length(var.regions) > 0 ? var.regions : [data.aws_region.current.region])

  contact_types = var.alternate_contact == null ? toset([]) : toset(["BILLING", "OPERATIONS", "SECURITY"])

  # aws_ssm_service_setting expects the setting's full ARN.
  ssm_setting_arn = "arn:${data.aws_partition.current.partition}:ssm:%s:${data.aws_caller_identity.current.account_id}:servicesetting%s"
}

# ---------------------------------------------------------------- account-wide

# S3.1: blocks public ACLs and policies only; private bucket policies keep working.
resource "aws_s3_account_public_access_block" "this" {
  count = var.s3_block_public_access ? 1 : 0

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# IAM.7
resource "aws_iam_account_password_policy" "this" {
  #checkov:skip=CKV_AWS_9:Forced rotation is optional (max_age_days). NIST SP 800-63B advises against it and IAM.7 does not require it.
  count = var.password_policy == null ? 0 : 1

  minimum_password_length        = var.password_policy.minimum_length
  password_reuse_prevention      = var.password_policy.reuse_prevention
  max_password_age               = var.password_policy.max_age_days
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
}

# Account.1
resource "aws_account_alternate_contact" "this" {
  for_each = local.contact_types

  alternate_contact_type = each.key
  name                   = var.alternate_contact.name
  title                  = var.alternate_contact.title
  email_address          = var.alternate_contact.email
  phone_number           = var.alternate_contact.phone
}

# ---------------------------------------------------------------- per region

# EC2.182
resource "aws_ebs_snapshot_block_public_access" "this" {
  for_each = local.regions
  region   = each.key

  state = var.snapshot_block_public_access
}

# EC2.7: new volumes only; existing volumes keep their current encryption.
resource "aws_ebs_encryption_by_default" "this" {
  for_each = local.regions
  region   = each.key

  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  for_each = { for r, arn in var.ebs_default_kms_key_arns : r => arn if contains(local.regions, r) }
  region   = each.key

  key_arn = each.value
}

# SSM.7
resource "aws_ssm_service_setting" "document_public_sharing" {
  for_each = local.regions
  region   = each.key

  setting_id    = format(local.ssm_setting_arn, each.key, "/ssm/documents/console/public-sharing-permission")
  setting_value = "Disable"
}

# SSM.6
resource "aws_ssm_service_setting" "automation_logging" {
  for_each = local.regions
  region   = each.key

  setting_id    = format(local.ssm_setting_arn, each.key, "/ssm/automation/customer-script-log-destination")
  setting_value = "CloudWatch"
}

# EC2.172: opt-in, see var.vpc_block_public_access.
resource "aws_vpc_block_public_access_options" "this" {
  for_each = var.vpc_block_public_access == "off" ? toset([]) : local.regions
  region   = each.key

  internet_gateway_block_mode = var.vpc_block_public_access
}

# EC2.2 is reported, not fixed: deleting a default VPC needs a human decision.
data "aws_vpcs" "default" {
  for_each = local.regions
  region   = each.key

  filter {
    name   = "is-default"
    values = ["true"]
  }
}
