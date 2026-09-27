variable "regions" {
  type        = list(string)
  description = "Regions to apply the regional settings in. Empty means the provider's region."
  default     = []
}

variable "s3_block_public_access" {
  type        = bool
  description = "Turn on all four account-level S3 Block Public Access settings (S3.1)."
  default     = true
}

variable "password_policy" {
  type = object({
    minimum_length   = optional(number, 14)
    reuse_prevention = optional(number, 24)
    max_age_days     = optional(number)
  })
  description = "IAM account password policy (IAM.7). All character classes are always required. Set to null to leave the policy unmanaged."
  default     = {}

  validation {
    condition     = var.password_policy == null || try(var.password_policy.minimum_length >= 8 && var.password_policy.reuse_prevention >= 1, false)
    error_message = "minimum_length must be at least 8 and reuse_prevention at least 1."
  }
}

variable "alternate_contact" {
  type = object({
    name  = string
    title = optional(string, "Security")
    email = string
    phone = string
  })
  description = "Alternate contact set as the BILLING, OPERATIONS and SECURITY contact (Account.1). Null leaves contacts unmanaged."
  default     = null
}

variable "snapshot_block_public_access" {
  type        = string
  description = "EBS snapshot Block Public Access state (EC2.182): block-all-sharing or block-new-sharing."
  default     = "block-all-sharing"

  validation {
    condition     = contains(["block-all-sharing", "block-new-sharing"], var.snapshot_block_public_access)
    error_message = "Use block-all-sharing or block-new-sharing."
  }
}

variable "ebs_default_kms_key_arns" {
  type        = map(string)
  description = "Optional customer managed KMS key per region for EBS default encryption. Regions not listed use the aws/ebs key."
  default     = {}
}

variable "vpc_block_public_access" {
  type        = string
  description = "VPC Block Public Access mode (EC2.172): off, block-ingress or block-bidirectional. Off by default because it also blocks intentionally public load balancers."
  default     = "off"

  validation {
    condition     = contains(["off", "block-ingress", "block-bidirectional"], var.vpc_block_public_access)
    error_message = "Use off, block-ingress or block-bidirectional."
  }
}
