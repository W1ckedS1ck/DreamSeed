# DreamSeed task runner — thin wrapper over the existing entry points.
# Everything delegates to scripts/lint.sh / check_env_contract.sh / deploy.sh,
# so there is a single source of truth (see docs/linters.md).
SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help lint lint-full fmt fmt-py secrets test test-bash test-env bench-install precommit cloudflare-ips dry-run

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

lint: ## Fast lint (shellcheck, ruff, ansible-lint, actionlint, zizmor, yamllint, ...)
	bash scripts/lint.sh --fast

lint-full: ## Full lint suite (adds terraform validate, tflint, gitleaks, trivy, secrets)
	bash scripts/lint.sh --full

fmt: ## terraform fmt (via scripts/lint.sh --fmt)
	bash scripts/lint.sh --fmt

fmt-py: ## ruff format (Python)
	ruff format .

secrets: ## Secrets audit (same checks as CI)
	bash scripts/lint.sh --secrets

test: ## Unit tests (pytest)
	python3 -m pytest tests/unit -q

test-bash: ## Bash unit tests (bats)
	bats --print-output-on-failure tests/bats

test-env: ## .env parser contract fixtures + differential fuzz
	bash scripts/check_env_contract.sh
	python3 tests/env/fuzz_env_parsers.py

bench-install: ## Compare pip vs uv install time for hash-pinned locks
	bash scripts/bench_python_install.sh

precommit: ## Run all pre-commit hooks on all files
	pre-commit run --all-files

cloudflare-ips: ## Verify the Cloudflare real-IP ranges are current
	bash scripts/lint.sh --cloudflare-ips

dry-run: ## Terraform/Ansible dry-run for prod (no changes)
	./deploy.sh prod -n --dry-run
