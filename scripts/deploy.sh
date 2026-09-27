#!/usr/bin/env bash
# Deploy cloudformation/account-baseline.yaml.
#
# Without --targets: one stack per region in the current account.
# With --targets: a service-managed StackSet that deploys the stack to every
# account under the given OUs (or the root) in each region, including accounts
# that join later. Run that from the management account or a StackSets
# delegated administrator.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh --regions LIST [options]

  -r, --regions LIST     comma-separated regions; the first is the home region
                         that applies the account-wide settings
  -p, --profile NAME     AWS CLI profile
      --targets IDS      comma-separated OU IDs or the root ID (r-xxxx): deploy
                         to every account under them with a StackSet
      --delegated-admin  call StackSets as a delegated administrator instead of
                         from the management account
      --name NAME        stack / StackSet name (default: account-baseline)
      --param KEY=VALUE  template parameter, repeatable (e.g. --param
                         ContactEmail=security@example.com)
  -h, --help
EOF
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/cloudformation/account-baseline.yaml"
REGIONS="" PROFILE="" TARGETS="" NAME="account-baseline" CALL_AS=SELF PARAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--regions) REGIONS="${2:?}"; shift ;;
    -p|--profile) PROFILE="${2:?}"; shift ;;
    --targets) TARGETS="${2:?}"; shift ;;
    --delegated-admin) CALL_AS=DELEGATED_ADMIN ;;
    --name) NAME="${2:?}"; shift ;;
    --param) PARAMS+=("${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REGIONS" ] || { usage >&2; exit 2; }

aws_() {
  if [ -n "$PROFILE" ]; then aws --profile "$PROFILE" "$@"; else aws "$@"; fi
}

IFS=',' read -r -a REGION_LIST <<<"$REGIONS"
HOME_REGION=${REGION_LIST[0]}
PARAMS=("HomeRegion=$HOME_REGION" ${PARAMS[@]+"${PARAMS[@]}"})

if [ -z "$TARGETS" ]; then
  for REGION in "${REGION_LIST[@]}"; do
    echo "== stack $NAME in $REGION"
    aws_ cloudformation deploy --region "$REGION" --stack-name "$NAME" \
      --template-file "$TEMPLATE" --capabilities CAPABILITY_IAM \
      --no-fail-on-empty-changeset --parameter-overrides "${PARAMS[@]}"
  done
  exit 0
fi

# ---- StackSet mode
CFN_PARAMS=()
for P in "${PARAMS[@]}"; do
  CFN_PARAMS+=("ParameterKey=${P%%=*},ParameterValue=${P#*=}")
done

stackset() { # stackset SUBCOMMAND ARGS...: a StackSet call in the home region
  local cmd=$1
  shift
  aws_ cloudformation "$cmd" --region "$HOME_REGION" --stack-set-name "$NAME" --call-as "$CALL_AS" "$@"
}

wait_for() { # wait_for OPERATION_ID
  local status
  while true; do
    status=$(stackset describe-stack-set-operation --operation-id "$1" \
      --query StackSetOperation.Status --output text)
    case "$status" in
      SUCCEEDED) echo "   $status"; return 0 ;;
      FAILED|STOPPED) echo "   $status: see 'aws cloudformation list-stack-set-operation-results'" >&2; return 1 ;;
    esac
    sleep 15
  done
}

if stackset describe-stack-set >/dev/null 2>&1; then
  echo "== updating StackSet $NAME"
  OP=$(stackset update-stack-set --template-body "file://$TEMPLATE" --capabilities CAPABILITY_IAM \
    --parameters "${CFN_PARAMS[@]}" --query OperationId --output text)
  wait_for "$OP"
else
  echo "== creating StackSet $NAME"
  stackset create-stack-set --template-body "file://$TEMPLATE" --capabilities CAPABILITY_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
    --parameters "${CFN_PARAMS[@]}" >/dev/null
fi

# Safe to repeat for service-managed StackSets: existing instances are kept.
echo "== deploying to $TARGETS in ${REGION_LIST[*]}"
OP=$(stackset create-stack-instances --deployment-targets "OrganizationalUnitIds=$TARGETS" \
  --regions "${REGION_LIST[@]}" \
  --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100,FailureTolerancePercentage=10 \
  --query OperationId --output text)
wait_for "$OP"
