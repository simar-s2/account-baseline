#!/usr/bin/env bash
# account-baseline.sh: apply the account- and region-level security settings
# that Security Hub (AWS Foundational Security Best Practices) flags on a new
# account, and report the ones that need a human decision.
#
#   Applied                                                      Scope
#   S3.1       account-level S3 Block Public Access              account
#   IAM.7      IAM password policy (14+ chars, all classes)      account
#   Account.1  alternate contacts (--contact-email)              account
#   EC2.182    block public sharing of EBS snapshots             region
#   SSM.7      block public sharing of SSM documents             region
#   EC2.7      EBS encryption by default for new volumes         region
#   SSM.6      SSM Automation logging to CloudWatch              region
#   EC2.172    VPC Block Public Access (--block-igw)             region
#
#   Reported
#   EC2.9      whether a private, NAT-routed subnet exists, so instances can
#              run without a public IP
#   EC2.2      default VPCs and whether anything uses them; --delete-default-vpcs
#              removes the ones with no network interfaces
#
# Every step is idempotent, so the script is safe to re-run.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: account-baseline.sh [options]

  -p, --profile NAME         AWS CLI profile (default: the current credentials)
  -r, --regions LIST         comma-separated regions, or "all" for every enabled
                             region (default: the profile's configured region)
      --contact-email ADDR   set the BILLING, OPERATIONS and SECURITY alternate
                             contacts (needs --contact-phone)
      --contact-name NAME    alternate contact name (default: "Security team")
      --contact-phone PHONE  alternate contact phone number
      --block-igw            turn on VPC Block Public Access (block-bidirectional).
                             Breaks intentional public ingress, so it is opt-in
      --delete-default-vpcs  delete default VPCs that have no network interfaces
      --dry-run              print the changes instead of making them; the
                             read-only reports still run
  -h, --help                 show this help
EOF
}

PROFILE="" REGIONS="" CONTACT_EMAIL="" CONTACT_NAME="Security team" CONTACT_PHONE=""
BLOCK_IGW=false DELETE_VPCS=false DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile) PROFILE="${2:?--profile needs a value}"; shift ;;
    -r|--regions) REGIONS="${2:?--regions needs a value}"; shift ;;
    --contact-email) CONTACT_EMAIL="${2:?--contact-email needs a value}"; shift ;;
    --contact-name) CONTACT_NAME="${2:?--contact-name needs a value}"; shift ;;
    --contact-phone) CONTACT_PHONE="${2:?--contact-phone needs a value}"; shift ;;
    --block-igw) BLOCK_IGW=true ;;
    --delete-default-vpcs) DELETE_VPCS=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$CONTACT_EMAIL" ] && [ -z "$CONTACT_PHONE" ]; then
  echo "--contact-email needs --contact-phone (the Account API requires both)" >&2
  exit 2
fi

aws_() {
  if [ -n "$PROFILE" ]; then aws --profile "$PROFILE" "$@"; else aws "$@"; fi
}

row() { printf '  %-30s %s\n' "$1" "$2"; }

# apply LABEL VALUE AWS_ARGS...: make one change (or describe it in dry-run mode)
apply() {
  local label=$1 value=$2
  shift 2
  if $DRY_RUN; then
    row "$label" "would set: $value"
  else
    aws_ "$@" >/dev/null
    row "$label" "$value"
  fi
}

if [ -z "$REGIONS" ]; then
  REGIONS="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws_ configure get region || true)}}"
  [ -n "$REGIONS" ] || { echo "no region configured; pass --regions" >&2; exit 2; }
elif [ "$REGIONS" = "all" ]; then
  REGIONS=$(aws_ ec2 describe-regions --region "${AWS_REGION:-us-east-1}" \
    --query 'Regions[].RegionName' --output text | tr '\t' ',')
fi
IFS=',' read -r -a REGION_LIST <<<"$REGIONS"

ACCOUNT_ID=$(aws_ sts get-caller-identity --query Account --output text)
MODE=""
if $DRY_RUN; then MODE=", dry run"; fi
echo "== account $ACCOUNT_ID${PROFILE:+ (profile $PROFILE)}$MODE =="

# S3.1: blocks public ACLs and policies only; private bucket policies keep working
apply "S3 Block Public Access" "all four settings on" \
  s3control put-public-access-block --account-id "$ACCOUNT_ID" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# IAM.7: only matters for the few IAM users that still have console passwords
apply "IAM password policy" "14+ chars, all classes, last 24 blocked" \
  iam update-account-password-policy \
  --minimum-password-length 14 \
  --require-symbols --require-numbers \
  --require-uppercase-characters --require-lowercase-characters \
  --allow-users-to-change-password \
  --password-reuse-prevention 24

# Account.1: security notices go to a monitored list, not one person's inbox
if [ -n "$CONTACT_EMAIL" ]; then
  for TYPE in BILLING OPERATIONS SECURITY; do
    apply "Alternate contact ($TYPE)" "$CONTACT_EMAIL" \
      account put-alternate-contact --alternate-contact-type "$TYPE" \
      --name "$CONTACT_NAME" --title "$CONTACT_NAME" \
      --email-address "$CONTACT_EMAIL" --phone-number "$CONTACT_PHONE"
  done
fi

for REGION in "${REGION_LIST[@]}"; do
  echo "== $REGION =="

  # EC2.182
  apply "EBS snapshot public sharing" "blocked (block-all-sharing)" \
    ec2 enable-snapshot-block-public-access --state block-all-sharing --region "$REGION"

  # SSM.7
  apply "SSM document public sharing" "disabled" \
    ssm update-service-setting --region "$REGION" \
    --setting-id /ssm/documents/console/public-sharing-permission --setting-value Disable

  # EC2.7: applies to new volumes only, with the aws/ebs key
  apply "EBS encryption by default" "on" \
    ec2 enable-ebs-encryption-by-default --region "$REGION"

  # SSM.6
  apply "SSM Automation logging" "CloudWatch" \
    ssm update-service-setting --region "$REGION" \
    --setting-id /ssm/automation/customer-script-log-destination --setting-value CloudWatch

  # EC2.172: opt-in because it also blocks load balancers meant to be public
  if $BLOCK_IGW; then
    apply "VPC Block Public Access" "block-bidirectional" \
      ec2 modify-vpc-block-public-access-options --region "$REGION" \
      --internet-gateway-block-mode block-bidirectional
  fi

  # EC2.9: instances without a public IP need a subnet whose route table sends
  # 0.0.0.0/0 to a NAT gateway (or VPC endpoints for everything they call)
  NAT_RTS=$(aws_ ec2 describe-route-tables --region "$REGION" \
    --query "RouteTables[?Routes[?starts_with(to_string(NatGatewayId),'nat-')]].RouteTableId" \
    --output text)
  if [ -n "$NAT_RTS" ]; then
    # SC2086: one argument per ID is intended. SC2016: the backticks are JMESPath.
    # shellcheck disable=SC2086,SC2016
    PRIVATE_SUBNETS=$(aws_ ec2 describe-route-tables --region "$REGION" --route-table-ids $NAT_RTS \
      --query 'RouteTables[].Associations[?SubnetId!=`null`].SubnetId' --output text | tr '\t' ' ')
    row "Private NAT-routed subnets" "${PRIVATE_SUBNETS:-(NAT route on the main route table)}"
  else
    row "Private NAT-routed subnets" "NONE: add a private subnet + NAT gateway before running instances without public IPs"
  fi

  # EC2.2: deleting a default VPC needs judgment, since a workload may use it
  VPC_ID=$(aws_ ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  if [ "$VPC_ID" = "None" ]; then
    row "Default VPC" "none"
    continue
  fi
  ENI_COUNT=$(aws_ ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(NetworkInterfaces)' --output text)
  row "Default VPC" "$VPC_ID ($ENI_COUNT network interfaces)"

  $DELETE_VPCS || continue
  if [ "$ENI_COUNT" != "0" ]; then
    row "" "kept: something is using it, investigate before deleting"
    continue
  fi
  if $DRY_RUN; then
    row "" "would delete $VPC_ID with its internet gateway and subnets"
    continue
  fi
  IGW=$(aws_ ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  if [ "$IGW" != "None" ]; then
    aws_ ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
    aws_ ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW"
  fi
  for SUBNET in $(aws_ ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' --output text); do
    aws_ ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET"
  done
  aws_ ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
  row "" "deleted $VPC_ID"
done

echo "Done. Security Hub updates the matching controls on their next evaluation."
