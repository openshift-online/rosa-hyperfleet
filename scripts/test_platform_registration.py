"""Local-only registration and smoke regressions: all AWS/HTTP calls are mocks."""

import json
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent


def run_bash(script, cwd, env):
    return subprocess.run(["bash", "-c", script], cwd=cwd,
                          env={**os.environ, **env}, capture_output=True, text=True)


@pytest.mark.parametrize("account,force,expected", [
    ("012345678901", False, False),
    ("012345678901", True, True),
    ("999999999999", True, True),
    ("999999999999", False, True),
])
def test_registration_role_identity(tmp_path, account, force, expected):
    log = tmp_path / "aws.log"
    script = f'''source "{ROOT}/scripts/pipeline-common/lib.sh"
aws() {{
  echo "$*|${{AWS_ACCESS_KEY_ID:-}}" >> "$MOCK_LOG"
  case "$1 $2" in
    "sts assume-role") echo 'operator-key operator-secret operator-token' ;;
    "sts get-caller-identity") echo "$RC_ACCOUNT" ;;
    "ssm get-parameter") echo "$RC_ACCOUNT" ;;
    *) return 99 ;;
  esac
}}
CENTRAL_ACCOUNT_ID=012345678901
_CENTRAL_AWS_ACCESS_KEY_ID=central-key
_CENTRAL_AWS_SECRET_ACCESS_KEY=central-secret
_CENTRAL_AWS_SESSION_TOKEN=central-token
REGIONAL_AWS_ACCOUNT_ID=ssm:///infra/stage/rc/account_id
TARGET_REGION=us-east-1
CLUSTER_ID=mc01
CHILD_ADMIN_ROLE_NAME=path/Operator
use_rc_account {"operator" if force else ""}
echo "KEY=$AWS_ACCESS_KEY_ID"
'''
    result = run_bash(script, tmp_path, {"MOCK_LOG": str(log), "RC_ACCOUNT": account})
    assert result.returncode == 0, result.stderr
    calls = log.read_text()
    assert "ssm get-parameter" in calls
    assert ("sts assume-role" in calls) == expected
    assert f"KEY={'operator-key' if expected else 'central-key'}" in result.stdout
    if expected:
        assert f"--role-arn arn:aws:iam::{account}:role/path/Operator" in calls
        assert "|central-key" in calls


@pytest.mark.parametrize("role,trust_failure", [("", False), ("Operator", True)])
def test_operator_missing_role_or_trust_has_no_fallback(tmp_path, role, trust_failure):
    script = f'''source "{ROOT}/scripts/pipeline-common/lib.sh"
aws() {{ echo 'AccessDenied' >&2; return 1; }}
CENTRAL_ACCOUNT_ID=012345678901
_CENTRAL_AWS_ACCESS_KEY_ID=central-key
_CENTRAL_AWS_SECRET_ACCESS_KEY=central-secret
_CENTRAL_AWS_SESSION_TOKEN=central-token
REGIONAL_AWS_ACCOUNT_ID=012345678901
CHILD_ADMIN_ROLE_NAME='{role}'
CLUSTER_ID=mc01
use_rc_account operator
echo fallback-success
'''
    result = run_bash(script, tmp_path, {})
    assert result.returncode != 0
    assert "fallback-success" not in result.stdout
    assert ("Failed to assume role" if trust_failure else "CHILD_ADMIN_ROLE_NAME") in result.stderr


def test_e2e_operator_profile(tmp_path):
    config = tmp_path / "source-config"
    config.write_text("[profile rrp-rc]\nregion=us-east-1\n")
    output = tmp_path / "operator-config"
    log = tmp_path / "calls"
    script = f'''source "{ROOT}/ci/setup-service-operator-profile.sh"
aws() {{
  echo "$*" >> "$MOCK_LOG"
  if [[ "$1 $2" == "sts get-caller-identity" ]]; then echo 720644165472; fi
}}
setup_operator_profile "$OUTPUT_CONFIG"
echo "PROFILE=$E2E_SERVICE_OPERATOR_PROFILE CONFIG=$AWS_CONFIG_FILE"
'''
    result = run_bash(script, tmp_path, {
        "AWS_CONFIG_FILE": str(config), "OUTPUT_CONFIG": str(output),
        "MOCK_LOG": str(log), "E2E_SERVICE_OPERATOR_PROFILE": "",
    })
    assert result.returncode == 0, result.stderr
    calls = log.read_text()
    assert "--profile rrp-rc" in calls
    assert "role_arn arn:aws:iam::720644165472:role/OrganizationAccountAccessRole" in calls
    assert "source_profile rrp-central" in calls
    assert "--profile rrp-service-operator" in calls
    assert f"PROFILE=rrp-service-operator CONFIG={output}" in result.stdout
    assert config.read_text() == "[profile rrp-rc]\nregion=us-east-1\n"
    assert output.stat().st_mode & 0o777 == 0o600


def test_e2e_operator_trust_failure(tmp_path):
    script = f'''source "{ROOT}/ci/setup-service-operator-profile.sh"
aws() {{ return 1; }}
if setup_operator_profile "$OUTPUT_CONFIG"; then
  echo fallback-success
else
  exit 1
fi
'''
    result = run_bash(script, tmp_path, {
        "E2E_SERVICE_OPERATOR_PROFILE": "explicit-operator",
        "OUTPUT_CONFIG": str(tmp_path / "unused"),
    })
    assert result.returncode != 0
    assert "fallback-success" not in result.stdout


def install_mocks(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    mock = bin_dir / "mock"
    mock.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as f:
    f.write(json.dumps({'command': name, 'args': args, 'key': os.environ.get('AWS_ACCESS_KEY_ID', '')}) + '\\n')
if name == 'aws':
    if args[:2] == ['sts', 'get-caller-identity']:
        print('012345678901')
    elif args[:2] == ['sts', 'assume-role']:
        print('operator-key operator-secret operator-token')
    else:
        sys.exit(99)
elif name == 'terraform':
    if args[:2] == ['output', '-raw']:
        print('https://example.invalid/prod')
elif name == 'sleep':
    pass
elif name in ('curl', 'awscurl'):
    url = next(a for a in args if a.startswith('https://'))
    post = '-X' in args and args[args.index('-X') + 1] == 'POST'
    if not url.endswith(('/api/v0/live', '/api/v0/ready', '/api/v0/management_clusters')):
        sys.exit(98)
    if post:
        payload = json.loads(args[args.index('-d') + 1])
        assert payload == {'id': 'mc01', 'region': 'us-east-1', 'accountId': '012345678901'}, payload
        code = int(os.environ['MOCK_STATUS'])
        body_code = int(os.environ.get('MOCK_POST_BODY_STATUS', code))
        body = {'id': 'mc01', 'region': 'us-east-1', 'accountId': '012345678901'} if body_code == 201 else {'kind': 'Status', 'status': 'Failure', 'reason': 'Conflict' if body_code == 409 else 'Forbidden', 'code': body_code, 'message': 'MC-MGMT-CREATE-005: management cluster already registered: mc01' if body_code == 409 else 'AUTHZ-DENIED: denied'}
    else:
        phase = 'HEALTH' if url.endswith(('/live', '/ready')) else 'LIST'
        code = int(os.environ.get('MOCK_' + phase + '_STATUS', '200'))
        body = {'kind': 'ManagementClusterList', 'items': [], 'total': 0}
    if name == 'curl':
        if '-o' in args:
            target = args[args.index('-o') + 1]
            if target != '/dev/null':
                Path(target).write_text(json.dumps(body))
        else:
            print(json.dumps(body))
        print(code, end='')
        sys.exit(int(os.environ.get('MOCK_POST_CURL_EXIT', '0') if post else os.environ.get('MOCK_CURL_EXIT', '0')))
    else:
        print(json.dumps(body))
        sys.exit(int(os.environ.get('MOCK_CURL_EXIT', '0')) or (0 if code < 400 else 1))
else:
    sys.exit(99)
''')
    mock.chmod(0o755)
    for name in ["aws", "terraform", "curl", "awscurl", "sleep"]:
        (bin_dir / name).symlink_to(mock)
    return {"PATH": f"{bin_dir}:{os.environ['PATH']}", "MOCK_LOG": str(tmp_path / "calls.jsonl"),
            "AWS_ACCESS_KEY_ID": "central-key", "AWS_SECRET_ACCESS_KEY": "central-secret",
            "AWS_SESSION_TOKEN": "central-token", "AWS_REGION": "us-east-1"}


@pytest.mark.parametrize("status,success,extra", [
    (201, True, {}), (409, True, {}), (403, False, {}), (502, False, {}),
    (502, False, {"MOCK_POST_BODY_STATUS": "409"}),
    (201, False, {"MOCK_CURL_EXIT": "7"}),
    (201, False, {"MOCK_POST_CURL_EXIT": "7"}),
])
def test_registration_current_contract(tmp_path, status, success, extra):
    env = install_mocks(tmp_path)
    env.update(TARGET_ACCOUNT_ID="012345678901", TARGET_REGION="us-east-1", MANAGEMENT_ID="mc01",
               ENVIRONMENT="stage", CHILD_ADMIN_ROLE_NAME="rosa-hyperfleet-account-admin", MOCK_STATUS=str(status))
    env.update(extra)
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "pipeline-common").symlink_to(ROOT / "scripts/pipeline-common")
    config = tmp_path / "deploy/stage/us-east-1"
    for name, data in [("pipeline-management-cluster-mc01-inputs", {"management_id": "mc01", "regional_aws_account_id": "012345678901"}),
                       ("pipeline-regional-cluster-inputs", {"regional_id": "regional"})]:
        directory = config / name
        directory.mkdir(parents=True)
        (directory / "terraform.json").write_text(json.dumps(data))
    (tmp_path / "terraform/config/regional-cluster").mkdir(parents=True)
    result = subprocess.run(["bash", str(ROOT / "scripts/buildspec/register.sh")], cwd=tmp_path,
                            env={**os.environ, **env}, capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    calls = [json.loads(line) for line in Path(env["MOCK_LOG"]).read_text().splitlines()]
    assumptions = [c for c in calls if c["command"] == "aws" and c["args"][:2] == ["sts", "assume-role"]]
    assert len(assumptions) == 1
    assert "arn:aws:iam::012345678901:role/rosa-hyperfleet-account-admin" in assumptions[0]["args"]
    posts = [c for c in calls if c["command"] == "curl" and "POST" in c["args"]]
    if extra.get("MOCK_CURL_EXIT"):
        assert not posts
    else:
        assert posts and all(c["key"] == "operator-key" for c in posts)


@pytest.mark.parametrize("field", ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
def test_smoke_requires_exported_credentials_before_aws_calls(tmp_path, field):
    env = install_mocks(tmp_path)
    env.update(MOCK_STATUS="201")
    env[field] = ""
    result = subprocess.run(["bash", str(ROOT / "ci/e2e-platform-api-test.sh"), "https://example.invalid/prod", "mc01"],
                            cwd=tmp_path, env={**os.environ, **env}, capture_output=True, text=True)
    assert result.returncode != 0
    assert "Export assumed operator credentials" in result.stderr
    assert not Path(env["MOCK_LOG"]).exists()


@pytest.mark.parametrize("status,success,extra", [
    (201, True, {}), (409, True, {}), (403, False, {}), (502, False, {}),
    (502, False, {"MOCK_POST_BODY_STATUS": "409"}),
    (201, False, {"MOCK_CURL_EXIT": "7"}),
    (201, False, {"MOCK_HEALTH_STATUS": "403"}),
    (201, False, {"MOCK_LIST_STATUS": "403"}),
    (201, False, {"MOCK_POST_CURL_EXIT": "7"}),
])
def test_smoke_current_contract(tmp_path, status, success, extra):
    env = install_mocks(tmp_path)
    env.update(MOCK_STATUS=str(status), AWS_ACCESS_KEY_ID="operator-key")
    env.update(extra)
    result = subprocess.run(["bash", str(ROOT / "ci/e2e-platform-api-test.sh"), "https://example.invalid/prod", "mc01"],
                            cwd=tmp_path, env={**os.environ, **env}, capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    calls = [json.loads(line) for line in Path(env["MOCK_LOG"]).read_text().splitlines()]
    posts = [c for c in calls if c["command"] in ("awscurl", "curl") and "POST" in c["args"]]
    assert len(posts) == (0 if any(key in extra for key in ["MOCK_CURL_EXIT", "MOCK_HEALTH_STATUS", "MOCK_LIST_STATUS"]) else 1)
    assert all("/prod/prod/" not in " ".join(c["args"]) for c in calls)
    assert all("resource_bundles" not in " ".join(c["args"]) for c in calls)
