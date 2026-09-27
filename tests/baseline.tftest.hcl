mock_provider "aws" {
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
}

run "defaults_to_the_provider_region" {
  command = plan

  assert {
    condition     = keys(aws_ebs_encryption_by_default.this) == ["us-east-1"]
    error_message = "With no regions set, only the provider region is configured."
  }
  assert {
    condition     = length(aws_s3_account_public_access_block.this) == 1 && length(aws_iam_account_password_policy.this) == 1
    error_message = "Account-wide settings are on by default."
  }
  assert {
    condition     = aws_iam_account_password_policy.this[0].minimum_password_length == 14 && aws_iam_account_password_policy.this[0].password_reuse_prevention == 24
    error_message = "Password policy defaults changed."
  }
  assert {
    condition     = length(aws_account_alternate_contact.this) == 0 && length(aws_vpc_block_public_access_options.this) == 0
    error_message = "Alternate contacts and VPC Block Public Access are opt-in."
  }
}

run "multiple_regions" {
  command = plan

  variables {
    regions                  = ["us-east-1", "eu-west-1"]
    ebs_default_kms_key_arns = { "eu-west-1" = "arn:aws:kms:eu-west-1:111122223333:key/example", "ap-south-1" = "arn:aws:kms:ap-south-1:111122223333:key/ignored" }
    vpc_block_public_access  = "block-bidirectional"
  }

  assert {
    condition     = toset(keys(aws_ssm_service_setting.document_public_sharing)) == toset(["us-east-1", "eu-west-1"])
    error_message = "Every regional setting is applied in every listed region."
  }
  assert {
    condition     = aws_ssm_service_setting.automation_logging["eu-west-1"].setting_id == "arn:aws:ssm:eu-west-1:111122223333:servicesetting/ssm/automation/customer-script-log-destination"
    error_message = "SSM service settings are addressed by their full ARN."
  }
  assert {
    condition     = keys(aws_ebs_default_kms_key.this) == ["eu-west-1"]
    error_message = "KMS keys for regions outside var.regions are ignored."
  }
  assert {
    condition     = length(aws_vpc_block_public_access_options.this) == 2
    error_message = "VPC Block Public Access follows var.regions when enabled."
  }
}

run "alternate_contacts" {
  command = plan

  variables {
    alternate_contact = { name = "Cloud security", email = "security@example.com", phone = "+1-555-0100" }
  }

  assert {
    condition     = toset(keys(aws_account_alternate_contact.this)) == toset(["BILLING", "OPERATIONS", "SECURITY"])
    error_message = "One contact per type."
  }
}

run "password_policy_can_be_left_alone" {
  command = plan

  variables {
    password_policy = null
  }

  assert {
    condition     = length(aws_iam_account_password_policy.this) == 0
    error_message = "A null policy is not managed."
  }
}

run "rejects_weak_password_policy" {
  command = plan

  variables {
    password_policy = { minimum_length = 6 }
  }

  expect_failures = [var.password_policy]
}
