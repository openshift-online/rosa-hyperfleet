import logging
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import yaml

from __init__ import TARGET_ENVIRONMENT
from aws import AWSCredentials
from codebuild_logs import download_codebuild_logs
from git import GitManager
from pipeline import PipelineMonitor
from yaml_utils import deep_merge, load_and_merge

PROVISION_TIMEOUT = 3600  # seconds (1 hour); total time for provisioning
TEARDOWN_TIMEOUT = 3600  # seconds (1 hour); total time for teardown

log = logging.getLogger(__name__)


def discover_region(env_config_dir: Path) -> str:
    """Find the single region YAML in an env config directory.

    Returns the region name (stem of the YAML file, e.g. "us-east-1").
    Errors if zero or more than one region file exists.
    """
    region_files = [f for f in env_config_dir.glob("*.yaml") if f.name != "defaults.yaml"]
    if len(region_files) == 0:
        raise ValueError(f"No region YAML file found in {env_config_dir}")
    if len(region_files) > 1:
        names = sorted(f.name for f in region_files)
        raise ValueError(
            f"Ephemeral provisioner supports exactly 1 region, found {len(region_files)}: {names}"
        )
    return region_files[0].stem


class EphemeralEnvOrchestrator:
    """Orchestrates an ephemeral environment lifecycle.

    Provision and teardown are independent operations that can run in separate
    processes. They share state via the ci_prefix (which determines branch names,
    pipeline names, and terraform state keys).

    Usage from CI steps:
        # Step 1: provision
        env = EphemeralEnvOrchestrator(repo, branch, creds_dir, region, ci_prefix)
        env.provision()

        # Step 2: run tests (separate process, same ci_prefix)

        # Step 3: teardown
        env = EphemeralEnvOrchestrator(repo, branch, creds_dir, region, ci_prefix)
        env.teardown()
    """

    def __init__(self, repo: str, branch: str, creds_dir: str, region: str, ci_prefix: str,
                 override_dir: str | None = None,
                 provision_overrides: list[tuple[str, str]] | None = None):
        self.repo = repo
        self.branch = branch
        self.creds_dir = creds_dir
        self.region = region
        self.ci_prefix = ci_prefix
        self.override_dir = Path(override_dir) if override_dir else None
        self.provision_overrides = provision_overrides or []
        self.provisioner_name = f"{ci_prefix}-pipeline-provisioner"
        # TODO: compute deterministic RC/MC pipeline names from rendered config
        # instead of using prefix-based discovery (e.g. {ci_prefix}-regional-pipe, {ci_prefix}-mc01-pipe)
        self.pipeline_prefix = f"{ci_prefix}-"
        self.aws: AWSCredentials | None = None
        self.central_monitor: PipelineMonitor | None = None
        self.target_monitor: PipelineMonitor | None = None
        self.git: GitManager | None = None

    def provision(self, save_state: str | None = None):
        """Provision the ephemeral environment (setup + bootstrap + wait for pipelines).

        Args:
            save_state: If set, save terraform outputs JSON to this path after provisioning.
        """
        self._setup_aws()

        git = GitManager(self.creds_dir, self.repo, self.branch)
        self.git = git
        git.create_ci_branch(self.ci_prefix)

        # Inject ephemeral environment into config.yaml (not checked into the repo)
        self._inject_ephemeral_config(git)

        # Apply provision override files (deep-merge YAML fragments into repo files)
        self._apply_provision_overrides(git)

        git.render_and_push("ci: add ephemeral environment and render deploy files")

        # Bootstrap pipeline provisioner
        self.central_monitor = PipelineMonitor(self.aws.session)
        self.target_monitor = PipelineMonitor(self.aws.target_session)
        self._bootstrap_pipeline_provisioner(git)

        # Wait for provisioning pipelines
        self._wait_for_provision()

        if save_state:
            self._save_terraform_outputs(git, save_state)

    def teardown(self, fire_and_forget: bool = False):
        """Tear down a previously provisioned ephemeral environment.

        Can run independently of provision() — reconnects to the existing
        CI branch and pipeline resources using the ci_prefix. The region is
        discovered from the CI branch's config (not the local workspace),
        so teardown always matches the provisioned environment.

        Args:
            fire_and_forget: If True, only pushes the initial infrastructure
                delete flags (Phase 1) and exits immediately without waiting
                for pipelines to complete. Phase 2 (delete_pipeline flags) and
                Phase 3 (pipeline-provisioner destruction) are intentionally
                skipped — teardown is expected to be driven to completion by
                external means (a periodic janitor job).
        """
        # Check out the CI branch first to discover region from its config
        git = GitManager(self.creds_dir, self.repo, self.branch)
        self.git = git
        git.checkout_ci_branch(self.ci_prefix)

        # Discover region from the CI branch's config
        env_config_dir = git.work_dir / "config" / TARGET_ENVIRONMENT
        self.region = discover_region(env_config_dir)
        log.info("Region (from CI branch): %s", self.region)

        self._setup_aws()

        # Collect CodeBuild logs before teardown destroys infrastructure.
        # In Prow, teardown runs as a separate step — this captures logs
        # from the provisioning phase that would otherwise be lost.
        self.collect_codebuild_logs()

        self.central_monitor = PipelineMonitor(self.aws.session)
        self.target_monitor = PipelineMonitor(self.aws.target_session)
        self._run_teardown(git, fire_and_forget=fire_and_forget)

    def resync(self):
        """Resync the CI branch: rebase onto latest source, re-inject config, re-render.

        Re-reads the environment config (including .ephemeral-env/ overrides if
        mounted) so that config changes are picked up alongside code changes.
        """
        self._setup_aws()

        git = GitManager(self.creds_dir, self.repo, self.branch)
        self.git = git
        git.resync_ci_branch(self.ci_prefix)

        self._inject_ephemeral_config(git)
        git.render_and_push("ci: resync ephemeral environment config")

    def collect_codebuild_logs(self):
        """Download CloudWatch logs for all CodeBuild projects matching our CI prefix.

        Writes each log group to a separate file in ARTIFACT_DIR (set by Prow)
        so they appear in the Prow artifacts UI. Sensitive values (AWS keys,
        session tokens) are redacted before writing.
        """
        artifact_dir = os.environ.get("ARTIFACT_DIR")
        if not artifact_dir:
            log.warning("ARTIFACT_DIR not set — skipping CodeBuild log collection")
            return

        if not self.aws or not self.aws.session:
            log.warning("AWS session not available — skipping log collection")
            return

        artifact_path = Path(artifact_dir) / "codebuild-logs"
        # Central region logs (pipeline-provisioner CodeBuild)
        files = download_codebuild_logs(self.aws.session, self.ci_prefix, artifact_path)
        # RC/MC builds live in the target account even when both sessions use the same region.
        files.extend(download_codebuild_logs(self.aws.target_session, self.ci_prefix, artifact_path))

        # Redact sensitive values (AWS keys, session tokens) from Prow artifacts
        for f in files:
            content = f.read_text()
            content = _redact_sensitive(content)
            f.write_text(content)

    def _setup_aws(self):
        """Set up AWS credentials and trust policies."""
        log.info("")
        log.info("==========================================")
        log.info("Setup: AWS Credentials")
        log.info("==========================================")

        self.aws = AWSCredentials(self.creds_dir, self.region)
        self.aws.setup_central_account()

    def _inject_ephemeral_config(self, git: GitManager):
        """Inject the ephemeral environment config into the cloned repo.

        If an override directory (.ephemeral-env/) is provided, it replaces the
        config/ephemeral/ directory entirely. Otherwise the repo's default
        config/ephemeral/ is used as-is.

        In both cases, AWS account IDs are injected into the region config from
        the runtime credentials (never from config files).
        """
        env_config_dir = git.work_dir / "config" / TARGET_ENVIRONMENT

        # Replace config with overrides if provided
        if self.override_dir and self.override_dir.exists():
            log.info("Applying environment overrides from %s", self.override_dir)
            # Ensure target directory exists and clear existing config
            env_config_dir.mkdir(parents=True, exist_ok=True)
            for existing in env_config_dir.glob("*.yaml"):
                existing.unlink()
            for override_file in self.override_dir.glob("*.yaml"):
                shutil.copy2(override_file, env_config_dir / override_file.name)

        # Validate: exactly 1 region file must exist (enforced by discover_region
        # at startup, but re-check after override replacement)
        region = discover_region(env_config_dir)
        if region != self.region:
            raise ValueError(
                f"Region in config ({region}) does not match expected region ({self.region}). "
                "This should not happen — region is derived from the same config."
            )

        # Read and validate the region config
        region_file = env_config_dir / f"{self.region}.yaml"
        with open(region_file) as f:
            region_config = yaml.safe_load(f) or {}

        # Validate provision_mcs
        if "provision_mcs" not in region_config:
            raise ValueError(
                f"Region config {region_file.name} must define 'provision_mcs'. "
                "Example:\n  provision_mcs:\n    mc01: {}"
            )
        mc_count = len(region_config["provision_mcs"])
        if mc_count > 1:
            raise ValueError(
                f"Ephemeral environments support at most 1 management cluster "
                f"(only 1 MC account available), but {mc_count} were defined in "
                f"{region_file.name}: {list(region_config['provision_mcs'].keys())}"
            )

        # Reject lifecycle flags that are managed by the provisioner
        for forbidden in ("delete", "delete_pipeline"):
            if forbidden in region_config:
                raise ValueError(
                    f"Region config must not set '{forbidden}' — "
                    "this is managed by the provisioner lifecycle."
                )

        # Inject runtime AWS account IDs
        regional_account_id = self.aws.get_target_account_id("regional")
        management_account_id = self.aws.get_target_account_id("management")

        log.info(
            "Injecting ephemeral environment: region=%s, regional=%s, management=%s",
            self.region,
            regional_account_id,
            management_account_id,
        )

        if "aws" not in region_config:
            region_config["aws"] = {}
        region_config["aws"]["account_id"] = regional_account_id
        region_config["aws"]["management_cluster_account_id"] = management_account_id

        with open(region_file, "w") as f:
            yaml.dump(region_config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    def _apply_provision_overrides(self, git: GitManager):
        """Deep-merge provision override files into the cloned repo.

        Each override is a (target_path, override_file) tuple where target_path
        is relative to the repo root and override_file is an absolute path to a
        YAML fragment. The fragment is deep-merged into the target file —
        dict keys are merged recursively, and list items are matched by 'name'
        field when present.
        """
        if not self.provision_overrides:
            return

        log.info("")
        log.info("Applying %d provision override(s):", len(self.provision_overrides))

        for target_path, override_file in self.provision_overrides:
            root = git.work_dir.resolve()
            target = (root / target_path).resolve()
            if not target.is_relative_to(root):
                raise ValueError(
                    f"Override target escapes repo root: {target_path}"
                )
            if not target.exists():
                raise FileNotFoundError(
                    f"Override target not found: {target_path} "
                    f"(resolved to {target})"
                )

            log.info("  %s <- %s", target_path, override_file)
            load_and_merge(target, override_file)

    def _bootstrap_pipeline_provisioner(self, git: GitManager):
        """Bootstrap the pipeline-provisioner pointing at the CI branch."""
        log.info("")
        log.info("==========================================")
        log.info("Bootstrapping Pipeline Provisioner")
        log.info("==========================================")

        bootstrap_script = git.work_dir / "scripts" / "bootstrap-central-account.sh"

        if not bootstrap_script.exists():
            raise FileNotFoundError(f"Bootstrap script not found at: {bootstrap_script}")

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)
        env["GITHUB_REPOSITORY"] = git.fork_repo
        env["GITHUB_BRANCH"] = git.ci_branch
        env["TARGET_ENVIRONMENT"] = TARGET_ENVIRONMENT
        env["NAME_PREFIX"] = git.ci_prefix

        log.info("Executing: %s", bootstrap_script)
        log.info("Env: REPO=%s, BRANCH=%s", git.fork_repo, git.ci_branch)

        sys.stdout.flush()
        sys.stderr.flush()

        try:
            subprocess.run(
                ["/bin/bash", str(bootstrap_script)],
                cwd=git.work_dir,
                env=env,
                stdout=sys.stdout,
                stderr=sys.stderr,
                text=True,
                check=True,
                timeout=PROVISION_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"bootstrap-central-account.sh timed out after {PROVISION_TIMEOUT}s"
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"bootstrap-central-account.sh failed with exit code {e.returncode}. "
                "Check the logs above for the specific shell error."
            )
        log.info("Pipeline provisioner bootstrapped with branch: %s", git.ci_branch)

    def _wait_for_provision(self):
        """Wait for provisioning pipelines to complete."""
        log.info("")
        log.info("==========================================")
        log.info("Provision: Waiting for Pipelines")
        log.info("==========================================")

        # Wait for pipeline-provisioner (in central region, us-east-1)
        provisioner_exec_id = self.central_monitor.wait_for_any_execution(self.provisioner_name)
        self.central_monitor.wait_for_completion(self.provisioner_name, provisioner_exec_id)

        # Discover RC/MC pipelines (in target region) by CI prefix, excluding the provisioner
        all_pipelines = [
            (name, exec_id)
            for name, exec_id in self.target_monitor.discover_pipelines(self.pipeline_prefix)
            if name != self.provisioner_name
        ]
        if not all_pipelines:
            raise RuntimeError("No RC/MC pipelines found after provisioner completed.")

        # Monitor all pipelines concurrently to capture failures in real-time
        failed = []
        with ThreadPoolExecutor(max_workers=len(all_pipelines)) as executor:
            # Submit all monitoring tasks
            future_to_pipeline = {
                executor.submit(self.target_monitor.wait_for_completion, name, exec_id): name
                for name, exec_id in all_pipelines
            }

            # Process results as they complete
            for future in as_completed(future_to_pipeline):
                pipeline_name = future_to_pipeline[future]
                try:
                    future.result()
                except (RuntimeError, TimeoutError) as e:
                    log.error("Pipeline '%s' failed: %s", pipeline_name, e)
                    failed.append(pipeline_name)

        if failed:
            self.collect_codebuild_logs()
            raise RuntimeError(
                f"{len(failed)} pipeline(s) failed during provisioning: {', '.join(failed)}"
            )

        log.info("All pipelines completed successfully.")

    def _save_terraform_outputs(self, git: GitManager, dest: str):
        """Fetch RC terraform outputs and write them to a file.

        Connects to the regional-cluster remote state in the RC account's
        S3 bucket and runs ``terraform output --json``.
        """
        log.info("")
        log.info("==========================================")
        log.info("Saving Terraform Outputs")
        log.info("==========================================")

        regional_account_id = self.aws.get_target_account_id("regional")
        state_bucket = f"terraform-state-{regional_account_id}-{self.region}"
        state_key = f"regional-cluster/{self.ci_prefix}-regional.tfstate"
        tf_dir = git.work_dir / "terraform" / "config" / "regional-cluster"

        env = os.environ.copy()
        env.update(self.aws.target_subprocess_env("regional"))

        log.info("State bucket: %s  key: %s", state_bucket, state_key)

        try:
            subprocess.run(
                [
                    "terraform", "init", "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=tf_dir,
                env=env,
                check=True,
                timeout=120,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"terraform init timed out for {tf_dir} "
                f"(bucket={state_bucket}, key={state_key})"
            ) from e

        try:
            result = subprocess.run(
                ["terraform", "output", "--json"],
                cwd=tf_dir,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"terraform output timed out for {tf_dir} "
                f"(bucket={state_bucket}, key={state_key})"
            ) from e

        dest_path = Path(dest)
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        dest_path.write_text(result.stdout)
        log.info("Terraform outputs written to %s", dest)

    def _run_teardown(self, git: GitManager, fire_and_forget: bool = False):
        """Tear down infrastructure via GitOps and destroy the pipeline-provisioner."""

        # Phase 1: Infrastructure teardown
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Infrastructure Destroy")
        log.info("==========================================")

        # Snapshot known executions (RC/MC pipelines are in the target region)
        pipeline_known = self.target_monitor.snapshot_pipeline_executions(self.pipeline_prefix)

        def set_delete_flag(region_config):
            region_config["delete"] = True
            for mc_name, mc_config in region_config.get("provision_mcs", {}).items():
                if mc_config is None:
                    region_config["provision_mcs"][mc_name] = mc_config = {}
                mc_config["delete"] = True

        git.modify_config(TARGET_ENVIRONMENT, self.region, set_delete_flag)

        if fire_and_forget:
            log.info(
                "Fire-and-forget mode: pushed infrastructure delete flags (Phase 1) "
                "and exiting. Phases 2 (delete_pipeline) and 3 (pipeline-provisioner "
                "destroy) will NOT run — complete teardown must be triggered separately."
            )
            return

        # Discover and wait for RC/MC pipeline executions (infra destroy, target region)
        teardown_pipelines = [
            (name, exec_id)
            for name, exec_id in self.target_monitor.discover_pipelines(self.pipeline_prefix, pipeline_known)
            if name != self.provisioner_name
        ]

        # Monitor all teardown pipelines concurrently
        if teardown_pipelines:
            with ThreadPoolExecutor(max_workers=len(teardown_pipelines)) as executor:
                future_to_pipeline = {
                    executor.submit(self.target_monitor.wait_for_completion, name, exec_id): name
                    for name, exec_id in teardown_pipelines
                }

                for future in as_completed(future_to_pipeline):
                    pipeline_name = future_to_pipeline[future]
                    try:
                        future.result()
                    except (RuntimeError, TimeoutError) as e:
                        log.error("Teardown pipeline '%s' failed: %s", pipeline_name, e)
                        # Continue with teardown even if infrastructure destroy fails

        # Phase 2: Pipeline teardown
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Pipeline Destroy")
        log.info("==========================================")

        # Snapshot again before pushing delete_pipeline flags (provisioner is in central region)
        provisioner_known = self.central_monitor.get_execution_ids(self.provisioner_name)

        def set_delete_pipeline_flag(region_config):
            region_config["delete_pipeline"] = True
            for mc_name, mc_config in region_config.get("provision_mcs", {}).items():
                if mc_config is None:
                    region_config["provision_mcs"][mc_name] = mc_config = {}
                mc_config["delete_pipeline"] = True

        git.modify_config(TARGET_ENVIRONMENT, self.region, set_delete_pipeline_flag)

        # Wait for pipeline-provisioner to destroy the pipelines (central region)
        provisioner_exec_id = self.central_monitor.wait_for_new_execution(
            self.provisioner_name, provisioner_known
        )
        self.central_monitor.wait_for_completion(self.provisioner_name, provisioner_exec_id)

        # Phase 3: Destroy pipeline-provisioner via terraform destroy
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Pipeline Provisioner Destroy")
        log.info("==========================================")
        self._destroy_pipeline_provisioner(git)

        log.info("Teardown complete.")

    def _destroy_pipeline_provisioner(self, git: GitManager):
        """Destroy the pipeline-provisioner via terraform destroy."""
        bootstrap_dir = git.work_dir / "terraform" / "config" / "central-account-bootstrap"

        account_id = self.aws.session.client("sts").get_caller_identity()["Account"]
        state_bucket = f"terraform-state-{account_id}"
        state_key = f"{git.ci_prefix}-central-account-bootstrap/terraform.tfstate"

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)

        try:
            subprocess.run(
                [
                    "terraform",
                    "init",
                    "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.aws.central_region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=bootstrap_dir,
                env=env,
                check=True,
                timeout=TEARDOWN_TIMEOUT,
            )

            # Destroy only the modules we own — the shared CodeStar
            # connection stays in state (harmless, per-CI-run state)
            # and is imported fresh on each apply.
            subprocess.run(
                ["terraform", "destroy", "-auto-approve",
                 "-target=module.pipeline_provisioner",
                 "-target=module.platform_image",
                 f"-var=github_repository={git.fork_repo}"],
                cwd=bootstrap_dir,
                env=env,
                check=True,
                timeout=TEARDOWN_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"Terraform teardown timed out after {TEARDOWN_TIMEOUT}s"
            )
        log.info("Pipeline-provisioner destroyed.")


# Patterns that match AWS secrets we don't want in Prow artifacts
_SENSITIVE_PATTERNS = [
    (re.compile(r"(?:AKIA|ASIA)[A-Z0-9]{16}"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"(?i)(aws_secret_access_key|secret_key)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)(aws_session_token|security_token)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
]


def _redact_sensitive(text: str) -> str:
    for pattern, replacement in _SENSITIVE_PATTERNS:
        text = pattern.sub(replacement, text)
    return text
