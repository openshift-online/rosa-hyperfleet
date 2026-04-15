.PHONY: help terraform-fmt terraform-init terraform-validate terraform-upgrade terraform-output-management terraform-output-regional helm-lint check-rendered-files ephemeral-provision ephemeral-teardown ephemeral-resync ephemeral-list ephemeral-shell ephemeral-bastion-rc ephemeral-bastion-mc ephemeral-port-forward-rc ephemeral-port-forward-mc ephemeral-port-forward-rc-all ephemeral-port-forward-mc-all ephemeral-e2e ephemeral-collect-logs int-shell int-bastion-rc int-bastion-mc int-port-forward-rc int-port-forward-mc int-port-forward-rc-all int-port-forward-mc-all int-e2e int-collect-logs check-docs pre-push

# Default target — interactive fzf picker, falls back to formatted list
help: ## Show this help message
	@if command -v fzf >/dev/null 2>&1; then \
		target=$$(grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
			awk -F ':.*## ' '{printf "%-35s - %s\n", $$1, $$2}' | \
			fzf --layout=reverse --prompt="make > " --header="Select a target to run" --no-sort | \
			awk '{print $$1}'); \
		if [ -n "$$target" ]; then \
			echo "Running: make $$target"; \
			$(MAKE) "$$target"; \
		fi; \
	else \
		grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
			awk -F ':.*## ' '{printf "  %-35s - %s\n", $$1, $$2}'; \
	fi

# Discover all directories containing Terraform files (excluding .terraform subdirectories)
TERRAFORM_DIRS := $(shell find ./terraform -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

# Root configurations only (terraform/config/*) — used for validate, which can't run on
# standalone child modules that declare provider configuration_aliases.
TERRAFORM_ROOT_DIRS := $(shell find ./terraform/config -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

terraform-fmt: ## Format all Terraform files
	@echo "🔧 Formatting Terraform files..."
	@echo "$(TERRAFORM_DIRS)" | tr ' ' '\n' | xargs -P 8 -I{} sh -c ' \
		echo "   Formatting $$1"; \
		terraform -chdir=$$1 fmt -recursive \
	' _ {}
	@echo "✅ Terraform formatting complete"

terraform-upgrade: ## Upgrade provider versions
	@echo "🔧 Upgrading Terraform provider versions..."
	@for dir in $(TERRAFORM_DIRS); do \
		echo "   Upgrading $$dir"; \
		terraform -chdir=$$dir init -upgrade -backend=false; \
	done
	@echo "✅ Terraform upgrade complete"

terraform-output-management: ## Get Terraform output for Management Cluster
	@cd terraform/config/management-cluster && terraform output -json

terraform-output-regional: ## Get Terraform output for Regional Cluster
	@cd terraform/config/regional-cluster && terraform output -json


# =============================================================================
# Validation & Testing Targets
# =============================================================================

# Initialize root Terraform configurations (no backend)
terraform-init:
	@echo "🔧 Initializing Terraform configurations..."
	@echo "$(TERRAFORM_ROOT_DIRS)" | tr ' ' '\n' | xargs -P 1 -I{} sh -c ' \
		echo "   Initializing $$1"; \
		if ! terraform -chdir=$$1 init -backend=false; then \
			echo "   ❌ Init failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || exit 1
	@echo "✅ Terraform initialization complete"

# Note: fmt runs on all dirs (modules + configs), but validate only runs on
# root configs because child modules with provider configuration_aliases
# cannot be validated in isolation.
terraform-validate: terraform-init ## Check formatting and validate all Terraform configs
	@echo "🔍 Checking Terraform formatting..."
	@echo "$(TERRAFORM_DIRS)" | tr ' ' '\n' | xargs -P 8 -I{} sh -c ' \
		echo "   Checking formatting in $$1"; \
		if ! terraform -chdir=$$1 fmt -check -recursive; then \
			echo "   ❌ Formatting check failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || { echo "❌ Terraform formatting check failed for one or more directories"; \
		echo "   Run '\''make terraform-fmt'\'' to fix formatting."; \
		exit 1; }
	@echo "🔍 Validating Terraform configurations..."
	@echo "$(TERRAFORM_ROOT_DIRS)" | tr ' ' '\n' | xargs -P 2 -I{} sh -c ' \
		echo "   Validating $$1"; \
		if ! terraform -chdir=$$1 validate; then \
			echo "   ❌ Validation failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || { echo "❌ Terraform validation failed for one or more directories"; \
		exit 1; }
	@echo "✅ Terraform validation complete"

# Global values (aws_region, environment, cluster_type) are injected by the
# ApplicationSet at deploy time, so we supply stubs here for linting.
HELM_LINT_SET := --set global.aws_region=us-east-1 --set global.environment=lint --set global.cluster_type=lint
helm-lint: ## Lint all Helm charts
	@echo "🔍 Linting Helm charts..."
	@failed=false; \
	for chart_dir in $$(find argocd/config -name "Chart.yaml" -exec dirname {} \; | sort); do \
		echo "   Linting $$chart_dir"; \
		if ! helm lint $$chart_dir $(HELM_LINT_SET); then \
			failed=true; \
		fi; \
	done; \
	if [ "$$failed" = true ]; then \
		echo "❌ Helm lint failed for one or more charts"; \
		exit 1; \
	fi
	@echo "✅ Helm lint complete"

check-rendered-files: ## Verify deploy/ is up to date with config.yaml
	@echo "🔍 Rendering deploy/ from config.yaml..."
	@uv run --no-cache scripts/render.py
	@echo "Checking for uncommitted changes in deploy/..."
	@if ! git diff --exit-code deploy/; then \
		echo ""; \
		echo "❌ Rendered files in deploy/ are out of date."; \
		echo "   Run 'uv run scripts/render.py' and commit the results."; \
		exit 1; \
	fi
	@untracked=$$(git ls-files --others --exclude-standard deploy/); \
	if [ -n "$$untracked" ]; then \
		echo ""; \
		echo "❌ Untracked rendered files found in deploy/:"; \
		echo "$$untracked"; \
		echo "   Run 'uv run scripts/render.py' and 'git add' the new files."; \
		exit 1; \
	fi
	@echo "✅ Rendered files are up to date"
	@echo "🔍 Checking config documentation..."
	@uv run --no-cache scripts/render.py --check-docs

check-docs: ## Check documentation formatting
	@echo "🔍 Checking documentation formatting..."
	@npx --no-install prettier --check '**/*.md'
	@echo "✅ Documentation formatting check complete"

pre-push: ## Run all CI validation checks (parallel)
	@echo "🚀 Running all CI validation checks..."
	@echo ""
	@echo "Formatting Terraform files..."
	@$(MAKE) terraform-fmt
	@echo ""
	@$(MAKE) -j4 check-docs check-rendered-files helm-lint terraform-validate
	@echo ""
	@echo "✅ All pre-push checks passed!"

# =============================================================================
# Ephemeral Environments
# =============================================================================
# Thin wrappers around scripts/dev/ephemeral-env.sh.
# See docs/development-environment.md for full usage guide.

REPO   ?= openshift-online/rosa-regional-platform
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)

ephemeral-provision: ## Provision an ephemeral environment
	@ID="$(ID)" REPO="$(REPO)" BRANCH="$(if $(filter command line,$(origin BRANCH)),$(BRANCH),)" \
		./scripts/dev/ephemeral-env.sh provision

ephemeral-teardown: ## Tear down an ephemeral environment
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh teardown

ephemeral-resync: ## Resync an ephemeral environment to your branch
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh resync

ephemeral-list: ## List ephemeral environments
	@./scripts/dev/ephemeral-env.sh list

ephemeral-shell: ## Interactive shell for Platform API access (ephemeral)
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh shell

ephemeral-bastion-rc: ## Connect to RC bastion in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh bastion --cluster-type regional

ephemeral-bastion-mc: ## Connect to MC bastion in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh bastion --cluster-type management

ephemeral-port-forward-rc: ## Port-forward to RC service in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type regional

ephemeral-port-forward-mc: ## Port-forward to MC service in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type management

ephemeral-port-forward-rc-all: ## Port-forward all RC services in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type regional --all

ephemeral-port-forward-mc-all: ## Port-forward all MC services in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type management --all

ephemeral-e2e: ## Run e2e tests against an ephemeral env
	@ID="$(ID)" E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/ephemeral-env.sh e2e

ephemeral-collect-logs: ## Collect logs from an ephemeral env (CLUSTER=rc|mc)
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh collect-logs $(CLUSTER)

# =============================================================================
# Integration Environment
# =============================================================================
# Thin wrappers around scripts/dev/int-env.sh.
# Uses AWS profiles with SAML auth (via rosa-regional-platform-internal).

int-shell: ## Interactive shell for Platform API access (int)
	@./scripts/dev/int-env.sh shell

int-bastion-rc: ## Connect to RC bastion in int env
	@./scripts/dev/int-env.sh bastion --cluster-type regional

int-bastion-mc: ## Connect to MC bastion in int env
	@./scripts/dev/int-env.sh bastion --cluster-type management

int-port-forward-rc: ## Port-forward to RC service in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type regional

int-port-forward-mc: ## Port-forward to MC service in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type management

int-port-forward-rc-all: ## Port-forward all RC services in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type regional --all

int-port-forward-mc-all: ## Port-forward all MC services in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type management --all

int-e2e: ## Run e2e tests against int env
	@E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/int-env.sh e2e

int-collect-logs: ## Collect logs from int env (CLUSTER=rc|mc)
	@./scripts/dev/int-env.sh collect-logs $(CLUSTER)
