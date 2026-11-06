# Setup

Every way to deploy it, and every option. The short version is in the [README](../README.md).

## Deploy

### Script

Needs the AWS CLI v2 and credentials for the target account.

```bash
git clone https://github.com/simar-s2/account-baseline && cd account-baseline
./account-baseline.sh --profile my-account --regions us-east-1,us-west-2 --dry-run   # show what would change
./account-baseline.sh --profile my-account --regions us-east-1,us-west-2
```

Add `--contact-email security@example.com --contact-phone +1-555-0100` to set the alternate contacts, and `--delete-default-vpcs` to remove default VPCs that have no network interfaces. `--regions all` covers every enabled region.

### Terraform

```hcl
module "account_baseline" {
  source = "git::https://github.com/simar-s2/account-baseline.git?ref=v0.1.0"

  regions = ["us-east-1", "us-west-2"]

  alternate_contact = {
    name  = "Cloud security team"
    email = "aws-security@example.com"
    phone = "+1-555-0100"
  }
}
```

See [examples/basic](../examples/basic) and [examples/complete](../examples/complete).

### CloudFormation

```bash
# One account: a stack per region (the first region also applies the account-wide settings)
scripts/deploy.sh --profile my-account --regions us-east-1,us-west-2

# Every account in the organization, including accounts that join later (run from the management account)
scripts/deploy.sh --profile management --regions us-east-1,us-west-2 --targets r-abcd
```

## Configuration

### Script options

| Option | Default | Description |
|---|---|---|
| `-p, --profile` | current credentials | AWS CLI profile |
| `-r, --regions` | the profile's region | Comma-separated regions, or `all` |
| `--contact-email`, `--contact-phone`, `--contact-name` | not set | Alternate contacts (email and phone are both required by the API) |
| `--block-igw` | off | VPC Block Public Access in `block-bidirectional` mode |
| `--delete-default-vpcs` | off | Delete default VPCs with no network interfaces |
| `--dry-run` | off | Print the changes instead of making them; the reports still run |

### Terraform inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `regions` | `list(string)` | `[]` | Regions for the regional settings. Empty means the provider's region |
| `s3_block_public_access` | `bool` | `true` | Account-level S3 Block Public Access |
| `password_policy` | `object` | `{}` (14 chars, reuse 24, no expiry) | `minimum_length`, `reuse_prevention`, `max_age_days`. `null` leaves the policy unmanaged |
| `alternate_contact` | `object` | `null` | `name`, `title`, `email`, `phone` for the three contact types |
| `snapshot_block_public_access` | `string` | `block-all-sharing` | Or `block-new-sharing` |
| `ebs_default_kms_key_arns` | `map(string)` | `{}` | Customer managed KMS key per region for EBS default encryption |
| `vpc_block_public_access` | `string` | `off` | `off`, `block-ingress` or `block-bidirectional` |

### Terraform outputs

| Name | Description |
|---|---|
| `regions` | Regions the regional settings were applied in |
| `default_vpc_ids` | Default VPC ID per region, or `null` where there is none |

### CloudFormation parameters

`HomeRegion`, `MinimumPasswordLength` (14), `PasswordReusePrevention` (24), `SnapshotBlockPublicAccess` (`block-all-sharing`), `VpcBlockPublicAccess` (`off`), `ContactEmail`, `ContactName`, `ContactPhone`. Pass them to the deploy script with `--param Key=Value`.
