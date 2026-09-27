"""Runs scripts/deploy.sh against the fake AWS CLI in tests/fake-aws."""

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAKE_AWS = ROOT / "tests" / "fake-aws"


def deploy(tmp_path, *args, stack_set_exists=False):
    scenario = json.loads((FAKE_AWS / "scenario.json").read_text())
    scenario["stack_set_exists"] = stack_set_exists
    (tmp_path / "scenario.json").write_text(json.dumps(scenario))
    log = tmp_path / "calls.jsonl"
    env = {
        "PATH": f"{FAKE_AWS}:{os.environ['PATH']}",
        "FAKE_AWS_LOG": str(log),
        "FAKE_AWS_SCENARIO": str(tmp_path / "scenario.json"),
        "HOME": str(tmp_path),
    }
    proc = subprocess.run([str(ROOT / "scripts" / "deploy.sh"), *args],
                          env=env, capture_output=True, text=True)
    calls = [json.loads(line)["args"] for line in log.read_text().splitlines()] if log.exists() else []
    return proc, calls


def value(args, flag):
    return args[args.index(flag) + 1]


def test_requires_regions(tmp_path):
    proc, calls = deploy(tmp_path)
    assert proc.returncode == 2 and calls == []


def test_one_stack_per_region_with_first_region_as_home(tmp_path):
    proc, calls = deploy(tmp_path, "--regions", "us-east-1,us-west-2",
                         "--param", "ContactName=Cloud security")
    assert proc.returncode == 0, proc.stderr
    assert [c[1] for c in calls] == ["deploy", "deploy"]
    for call in calls:
        overrides = call[call.index("--parameter-overrides") + 1:]
        assert overrides == ["HomeRegion=us-east-1", "ContactName=Cloud security"]


def test_creates_stack_set_then_instances(tmp_path):
    proc, calls = deploy(tmp_path, "--regions", "us-east-1,us-west-2", "--targets", "r-abcd")
    assert proc.returncode == 0, proc.stderr
    cmds = [c[1] for c in calls]
    assert cmds == ["describe-stack-set", "create-stack-set", "create-stack-instances",
                    "describe-stack-set-operation"]
    create = calls[1]
    assert value(create, "--permission-model") == "SERVICE_MANAGED"
    assert "Enabled=true" in value(create, "--auto-deployment")
    assert value(create, "--call-as") == "SELF"
    instances = calls[2]
    assert value(instances, "--deployment-targets") == "OrganizationalUnitIds=r-abcd"
    assert instances[instances.index("--regions") + 1:][:2] == ["us-east-1", "us-west-2"]


def test_updates_existing_stack_set_as_delegated_admin(tmp_path):
    proc, calls = deploy(tmp_path, "--regions", "us-east-1", "--targets", "ou-abcd-11111111",
                         "--delegated-admin", stack_set_exists=True)
    assert proc.returncode == 0, proc.stderr
    assert [c[1] for c in calls][:3] == ["describe-stack-set", "update-stack-set",
                                         "describe-stack-set-operation"]
    assert all(value(c, "--call-as") == "DELEGATED_ADMIN" for c in calls)
