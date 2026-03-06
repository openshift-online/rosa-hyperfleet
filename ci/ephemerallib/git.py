import base64
import json
import logging
import os
import re
import subprocess
import tempfile
from pathlib import Path

import yaml

log = logging.getLogger(__name__)

GIT_TIMEOUT = 120  # seconds; clone/push can be slow on large repos
HTTP_TIMEOUT = 30  # seconds; GitHub API calls
RENDER_TIMEOUT = 300  # seconds; render.py may run terraform/heavy scripts


class GitManager:
    """Manages git operations for CI branch lifecycle.

    Creates a CI-owned branch from a source repo/branch, handles commits and
    pushes. CI branches are intentionally kept for post-run troubleshooting.
    """

    def __init__(self, creds_dir: str, repo: str, branch: str):
        self.creds_dir = Path(creds_dir)
        self.source_repo = repo
        self.source_branch = branch
        self.work_dir = None
        self.ci_branch = None
        self.ci_prefix = None
        self.fork_repo = None
        self._auth_header = None

    def _github_token(self) -> str:
        """Read the git token from credentials directory or environment."""
        env_token = os.environ.get("GITHUB_TOKEN")
        if env_token:
            return env_token
        return (self.creds_dir / "github_token").read_text().strip()

    def _setup_auth(self, token: str):
        """Derive and cache the HTTP auth header from a GitHub token."""
        creds = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        self._auth_header = f"Authorization: Basic {creds}"

    def _run_git(self, *args, cwd=None, check=True, auth=False) -> subprocess.CompletedProcess:
        """Run a git command.

        Args:
            auth: When True, inject http.extraHeader for token auth so that
                  remote URLs stay tokenless (no secrets in .git/config or
                  error messages).
        """
        cmd = ["git"]
        if auth and self._auth_header:
            cmd += ["-c", f"http.extraHeader={self._auth_header}"]
        cmd += list(args)
        result = subprocess.run(
            cmd, cwd=cwd or self.work_dir, check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=GIT_TIMEOUT,
        )
        if check and result.returncode != 0:
            if auth:
                # Suppress output for auth operations — stderr may contain
                # parts of the Authorization header on failure.
                raise RuntimeError(
                    f"git {args[0]} failed (exit {result.returncode})"
                )
            raise RuntimeError(
                f"git {args[0]} failed (exit {result.returncode})\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        return result

    def _resolve_fork_owner(self, token: str) -> str:
        """Get the GitHub username associated with the git token."""
        import urllib.request

        url = "https://api.github.com/user"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"token {token}"},
        )
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            data = json.loads(resp.read())
        return data["login"]

    def create_ci_branch(self, ci_prefix: str):
        """Clone source repo/branch and create a CI branch.

        Clones from the source (upstream) repo, then adds the token owner's
        fork as a 'ci' remote and pushes the CI branch there.

        Args:
            ci_prefix: Unique prefix for this run (e.g. 'ci-a1b2c3').
                       Used in branch name, resource names, and state keys.
        """
        self.ci_prefix = ci_prefix
        sanitized = re.sub(r"[/]", "-", self.source_branch)
        self.ci_branch = f"{self.ci_prefix}-{sanitized}-ci"

        token = self._github_token()
        self._setup_auth(token)
        clone_url = f"https://github.com/{self.source_repo}.git"

        tmpdir = tempfile.mkdtemp(prefix="ephemeral-")
        self.work_dir = Path(tmpdir) / "repo"

        log.info("Cloning %s (branch: %s)", self.source_repo, self.source_branch)
        self._run_git(
            "clone", "--branch", self.source_branch, "--single-branch", clone_url, str(self.work_dir),
            cwd=".", auth=True,
        )
        head = self._run_git("rev-parse", "HEAD")
        log.info("Cloned at %s (https://github.com/%s/tree/%s)", head.stdout.strip(), self.source_repo, head.stdout.strip())

        # Configure git identity
        self._run_git("config", "user.email", "ci-bot@rosa-regional-platform.dev")
        self._run_git("config", "user.name", "ROSA CI Bot")

        # Add the token owner's fork as the push remote
        fork_owner = self._resolve_fork_owner(token)
        repo_name = self.source_repo.split("/")[-1]
        self.fork_repo = f"{fork_owner}/{repo_name}"
        fork_url = f"https://github.com/{self.fork_repo}.git"
        self._run_git("remote", "add", "ci", fork_url)
        log.info("Push remote: %s (fork of %s)", self.fork_repo, self.source_repo)

        # Create and push CI branch to the fork
        self._run_git("checkout", "-b", self.ci_branch)
        self._run_git("push", "-u", "ci", self.ci_branch, auth=True)

        log.info("Created CI branch: %s on %s", self.ci_branch, self.fork_repo)

    def checkout_ci_branch(self, ci_prefix: str):
        """Clone the fork and check out an existing CI branch.

        Used for reconnecting to a previously provisioned environment (e.g. teardown).

        Args:
            ci_prefix: The CI prefix used during provisioning (e.g. 'ci-a1b2c3').
        """
        self.ci_prefix = ci_prefix
        sanitized = re.sub(r"[/]", "-", self.source_branch)
        self.ci_branch = f"{self.ci_prefix}-{sanitized}-ci"

        token = self._github_token()
        self._setup_auth(token)

        # Resolve fork
        fork_owner = self._resolve_fork_owner(token)
        repo_name = self.source_repo.split("/")[-1]
        self.fork_repo = f"{fork_owner}/{repo_name}"
        fork_url = f"https://github.com/{self.fork_repo}.git"

        tmpdir = tempfile.mkdtemp(prefix="ephemeral-")
        self.work_dir = Path(tmpdir) / "repo"

        log.info("Cloning %s (branch: %s)", self.fork_repo, self.ci_branch)
        self._run_git(
            "clone", "--branch", self.ci_branch, "--single-branch", fork_url, str(self.work_dir),
            cwd=".", auth=True,
        )

        # Configure git identity
        self._run_git("config", "user.email", "ci-bot@rosa-regional-platform.dev")
        self._run_git("config", "user.name", "ROSA CI Bot")

        # Add fork as push remote (same repo for CI branches)
        self._run_git("remote", "add", "ci", fork_url)

        log.info("Checked out existing CI branch: %s on %s", self.ci_branch, self.fork_repo)

    def push(self, message: str):
        """Stage all changes, commit, and push to the CI branch."""
        self._run_git("add", "-A")

        result = self._run_git("diff", "--cached", "--quiet", check=False)
        if result.returncode == 0:
            log.info("No changes to commit, skipping push")
            return

        self._run_git("commit", "-m", message)
        self._run_git("push", "ci", self.ci_branch, auth=True)
        log.info("Pushed: %s", message)

    def render_and_push(self, message: str):
        """Run render.py in the work directory, then commit and push."""
        render_script = self.work_dir / "scripts" / "render.py"
        log.info("Running render.py (ci_prefix=%s)", self.ci_prefix)
        env = os.environ.copy()
        if self.ci_prefix:
            env["CI_PREFIX"] = self.ci_prefix
        result = subprocess.run(
            ["uv", "run", "--no-cache", str(render_script)],
            cwd=self.work_dir,
            env=env,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=RENDER_TIMEOUT,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"render.py failed (exit {result.returncode})\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        self.push(message)

    def modify_config(self, environment: str, callback):
        """Load an environment config file, apply callback modifications, render, and push.

        Args:
            environment: Environment name (maps to config/environments/<name>.config.yaml)
            callback: A function that receives and modifies the environment config dict.
        """
        env_file = self.work_dir / "config" / "environments" / f"{environment}.config.yaml"
        if not env_file.exists():
            raise FileNotFoundError(
                f"Environment config not found: {env_file}"
            )

        with open(env_file) as f:
            env_config = yaml.safe_load(f) or {}

        callback(env_config)

        with open(env_file, "w") as f:
            yaml.dump(env_config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

        self.render_and_push(f"ci: update {environment} config")

