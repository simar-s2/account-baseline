"""Runs account-baseline.sh against the fake AWS CLI in tests/fake-aws."""

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "account-baseline.sh"
FAKE_AWS = ROOT / "tests" / "fake-aws"
WRITE_PREFIXES = ("put-", "update-", "enable-", "modify-", "create-", "delete-", "detach-")


def run(tmp_path, *args, scenario=None):
    log = tmp_path / "calls.jsonl"
    env = {
        "PATH": f"{FAKE_AWS}:{os.environ['PATH']}",
        "FAKE_AWS_LOG": str(log),
        "HOME": str(tmp_path),
    }
    if scenario:
        path = tmp_path / "scenario.json"
        path.write_text(json.dumps(scenario))
        env["FAKE_AWS_SCENARIO"] = str(path)
    proc = subprocess.run([str(SCRIPT), *args], env=env, capture_output=True, text=True)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return proc, calls


def ops(calls, name, region=None):
    return [
        c for c in calls
        if c["args"][1] == name and (region is None or c["opts"].get("region") == region)
    ]


def writes(calls):
    return [c for c in calls if c["args"][1].startswith(WRITE_PREFIXES)]


def test_help(tmp_path):
    proc, calls = run(tmp_path, "--help")
    assert proc.returncode == 0
    assert "Usage: account-baseline.sh" in proc.stdout
    assert calls == []


def test_unknown_option_is_rejected(tmp_path):
    proc, _ = run(tmp_path, "--nope")
    assert proc.returncode == 2
    assert "unknown option: --nope" in proc.stderr


def test_applies_every_control_once_per_scope(tmp_path):
    proc, calls = run(tmp_path, "--regions", "us-east-1,us-west-2")
    assert proc.returncode == 0, proc.stderr
    assert len(ops(calls, "put-public-access-block")) == 1
    assert len(ops(calls, "update-account-password-policy")) == 1
    for region in ("us-east-1", "us-west-2"):
        assert len(ops(calls, "enable-snapshot-block-public-access", region)) == 1
        assert len(ops(calls, "enable-ebs-encryption-by-default", region)) == 1
        settings = {c["args"][c["args"].index("--setting-id") + 1]
                    for c in ops(calls, "update-service-setting", region)}
        assert settings == {
            "/ssm/documents/console/public-sharing-permission",
            "/ssm/automation/customer-script-log-destination",
        }


def test_s3_block_public_access_targets_the_caller_account(tmp_path):
    _, calls = run(tmp_path)
    (call,) = ops(calls, "put-public-access-block")
    assert call["args"][call["args"].index("--account-id") + 1] == "111122223333"


def test_defaults_to_the_configured_region(tmp_path):
    proc, calls = run(tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert {c["opts"]["region"] for c in ops(calls, "enable-ebs-encryption-by-default")} == {"us-east-1"}


def test_all_regions(tmp_path):
    proc, calls = run(tmp_path, "--regions", "all")
    assert proc.returncode == 0, proc.stderr
    regions = {c["opts"]["region"] for c in ops(calls, "enable-ebs-encryption-by-default")}
    assert regions == {"us-east-1", "us-west-2"}


def test_dry_run_changes_nothing(tmp_path):
    proc, calls = run(tmp_path, "--regions", "us-east-1,us-west-2", "--dry-run",
                      "--delete-default-vpcs", "--block-igw",
                      "--contact-email", "security@example.com", "--contact-phone", "+1-555-0100")
    assert proc.returncode == 0, proc.stderr
    assert writes(calls) == []
    assert "would set: all four settings on" in proc.stdout
    assert "would delete vpc-0a1b2c3d4e5f60021" in proc.stdout


def test_default_vpcs_are_only_reported_without_the_flag(tmp_path):
    proc, calls = run(tmp_path, "--regions", "us-east-1,us-west-2")
    assert ops(calls, "delete-vpc") == []
    assert "vpc-0a1b2c3d4e5f60021 (0 network interfaces)" in proc.stdout


def test_deletes_only_unused_default_vpcs(tmp_path):
    proc, calls = run(tmp_path, "--regions", "us-east-1,us-west-2", "--delete-default-vpcs")
    assert proc.returncode == 0, proc.stderr
    (deleted,) = ops(calls, "delete-vpc")
    assert deleted["opts"]["region"] == "us-east-1"
    assert len(ops(calls, "delete-subnet", "us-east-1")) == 2
    assert len(ops(calls, "delete-internet-gateway", "us-east-1")) == 1
    assert ops(calls, "delete-subnet", "us-west-2") == []
    assert "kept: something is using it" in proc.stdout


def test_no_default_vpc(tmp_path):
    scenario = {"account_id": "111122223333", "regions": {"eu-west-1": {}}}
    proc, calls = run(tmp_path, "--regions", "eu-west-1", "--delete-default-vpcs", scenario=scenario)
    assert proc.returncode == 0, proc.stderr
    assert "Default VPC" in proc.stdout and "none" in proc.stdout
    assert ops(calls, "delete-vpc") == []


def test_reports_missing_private_subnet(tmp_path):
    proc, _ = run(tmp_path, "--regions", "us-west-2")
    assert "NONE: add a private subnet + NAT gateway" in proc.stdout


def test_vpc_block_public_access_is_opt_in(tmp_path):
    _, calls = run(tmp_path)
    assert ops(calls, "modify-vpc-block-public-access-options") == []
    _, calls = run(tmp_path, "--block-igw")
    assert len(ops(calls, "modify-vpc-block-public-access-options")) == 1


def test_alternate_contacts(tmp_path):
    proc, calls = run(tmp_path, "--contact-email", "security@example.com",
                      "--contact-phone", "+1-555-0100")
    assert proc.returncode == 0, proc.stderr
    types = [c["args"][c["args"].index("--alternate-contact-type") + 1]
             for c in ops(calls, "put-alternate-contact")]
    assert types == ["BILLING", "OPERATIONS", "SECURITY"]


@pytest.mark.parametrize("args", [["--contact-email", "security@example.com"], ["--profile"]])
def test_incomplete_options_fail_before_any_call(tmp_path, args):
    proc, calls = run(tmp_path, *args)
    assert proc.returncode != 0
    assert calls == []
