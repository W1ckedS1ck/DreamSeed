# Linters in DreamSeed

## Overview

There are 2 layers of linting:

- **Local**: `./deploy.sh --lint` or `./scripts/lint.sh` — fast mode covers ShellCheck, ruff (lint + format), mypy, bats, ansible-lint, actionlint, zizmor, yamllint, Renovate, markdownlint, Cloudflare IPs. Run `./scripts/lint.sh --full --ci` for the full suite (adds terraform fmt, tflint, terraform validate, gitleaks, Trivy, secrets audit; `--ci` just adds GitHub annotations)
- **CI on GitHub**: `ci.yml` (12 jobs on push — 11 on PRs, Deploy Check is push-only; 11 required for merge)
- **Task runner**: `make help` lists shortcuts (`make lint`, `make lint-full`, `make test-env`, ...). Each delegates to the same scripts as CI — one source of truth.

The `.env Parser Contract` job runs both the fixture contract (`scripts/check_env_contract.sh`) and a deterministic differential fuzzer (`tests/env/fuzz_env_parsers.py`) that asserts `lib/env.sh`, `common_functions.sh load_env` and `env_loader.py` agree on generated `.env` inputs.

---

## All Linters

| # | Tool | Layer | What it checks | Language |
|---|------|-------|----------------|----------|
| 1 | **ShellCheck** | local + CI | `deploy.sh`, `scripts/*.sh`, `.github/scripts/*.sh`, composite-action `run:` blocks | Bash |
| 2 | **ruff** | local + CI (pre-commit) | every `.py` in the repo (`ruff check .`) + formatter (`ruff format --check .`); rules in `ruff.toml` | Python |
| 2b | **mypy** | local + CI | `mypy.ini`: `scripts/`, `lib/`, `.github/actions/`, `docs/codemap/`, `tests/`; `check_untyped_defs` on | Python |
| 3 | **ansible-lint** | local + CI | `ansible/playbook-*.yml`, `ansible-roles/*/tasks/*.yml` | YAML/Ansible |
| 4 | **tflint** | local + CI | `terraform/aws/*.tf`, `terraform/hetzner/*.tf`, `terraform/grafana/*.tf`, `terraform/cloudflare/*.tf` | HCL/Terraform |
| 5 | **terraform validate** | CI | `*.tf` syntax | HCL |
| 6 | **Trivy** | CI | Security misconfigurations in `terraform/` | IaC Security |
| 7 | **gitleaks** | CI | Secret scanning across full git history | Git |
| 8 | **pre-commit** | CI + local | YAML, large files, merge conflicts, keys | Git hooks |
| 9 | **markdownlint-cli2** | local | `docs/**/*.md`, `README.md` | Markdown |
| 10 | **Checkov** | CI | IaC security scanning in `terraform/` | IaC Security |
| 11 | **actionlint** | CI | `.github/workflows/*.yml` syntax | GitHub Actions |
| 12 | **yamllint** | CI + local | generic YAML (`.github/`, `ansible/`, configs) | YAML |
| 13 | **zizmor** | CI | GitHub Actions security (workflow attacks, secrets) | GitHub Actions |
| 14 | **Renovate Config Validator** | local + CI | `renovate.json` schema + custom manager patterns (runs in `--fast` and in the pre-commit CI job) | JSON/RegEx |
| 15 | **Cloudflare IP ranges** | local | vendored `cloudflare-realip.conf` vs live `cloudflare.com/ips` (runs in `--fast`) | Data |
| 16 | **Secrets audit** | local + CI | `.gitignore` excludes (`secrets/`, `.env`), `secrets/` not tracked in git, no hardcoded-secret patterns in tracked files | Secrets |
| 17 | **Deploy Check** | CI | real `deploy.sh -c` smoke test (env parse, vault, playbook syntax) | orchestration |
| 18 | **Env parser contract** | local + CI | `scripts/check_env_contract.sh` — all 3 .env parsers produce identical output on contract fixtures (`tests/env/`); run before editing `lib/env.sh`, `scripts/common_functions.sh` or `scripts/env_loader.py` | bash+python |
| 19 | **terraform-docs** | local (pre-commit) | regenerates per-root `terraform/<root>/README.md` from module docs; one hook per root (aws/hetzner/grafana/cloudflare), graceful skip when binary is absent | HCL → Markdown |
| 20 | **bats** | local + CI | `tests/bats/*.bats` — unit tests for pure helpers in `lib/` and `scripts/common_functions.sh` (arg parsing, target resolution, `.env` parsing, formatting) | Bash |

---

## Details

### 2b. mypy (Python types)

Config: `mypy.ini` (`python_version = 3.12`, `check_untyped_defs = true`, `ignore_missing_imports`).
Run locally: `make types` (or `./scripts/lint.sh --mypy`). CI runs it as a step of the required
`.env Parser Contract` job; the same job runs `make test`'s coverage floor (80 % over the modules the
pytest suite actually exercises — `scripts/env_loader.py`/`lint_actions.py` are covered by the parser
contract and the lint itself, `telegram_bot.py` is network-bound).

### 1. ShellCheck (Bash)

**Type:** static Bash analyzer.
**Catches:** uninitialized variables, `set -e` disabled by `||`, temp file race conditions, incorrect substitutions, quoting issues.
**Example:** `$var` instead of `"$var"` (breaks if value contains spaces).

### 2. ruff (Python)

**Type:** Python linter + formatter (replaces flake8 + isort + pyflakes + Black).
**Scope:** every `.py` file in the repo — `scripts/`, `lib/`, `tests/`, `.github/actions/chatops/` and `docs/codemap/`. Rules are explicit in `ruff.toml` (`E`, `F`, `W`, `I`, `UP`, `B`, `SIM`, `S`, `RUF`) so a ruff upgrade cannot silently change the gate.
**Catches:** unused imports, syntax errors, security issues (bandit `S` rules), pyupgrade suggestions, import order, and formatting drift (`ruff format --check`).

### 3. ansible-lint (YAML/Ansible)

**Type:** Ansible playbook and role linter.
**Catches:** banned modules (e.g., `command: rm` instead of `file: state=absent`), incorrect task names, missing handlers, variable leaks, unsafe shell.

### 4. tflint (Terraform)

**Type:** Terraform linter.
**Catches:** deprecated syntax, wrong resource types, provider version incompatibilities.

### 5. terraform validate (Terraform)

**Type:** syntax validator.
**Catches:** HCL syntax errors, incorrect resource references.
**Difference from tflint:** validate checks grammar; tflint checks provider best practices.

### 6. Trivy (IaC Security)

**Type:** infrastructure vulnerability scanner.
**Catches:** open SSH/HTTP on `0.0.0.0/0` (intentional here, but Trivy flags it), public S3 buckets, missing disk encryption, incorrect IAM policies.

### 7. gitleaks (Secrets)

**Type:** git history secret scanner.
**Catches:** committed `TG_TOKEN=`, `password=`, PEM-encoded private keys (e.g. in `.pem` files), AWS keys, GitHub tokens.
**Why not just rely on .gitignore:** gitleaks catches things that were committed before being added to `.gitignore`.

### 8. pre-commit (Git hooks)

**Type:** pre-commit hook runner.
**Catches:** invalid YAML, files >10MB, merge conflict markers (`<<<<<<<`), accidentally added private keys, missing shebangs.

### 9. markdownlint-cli2 (Markdown)

**Type:** Markdown linter.
**Catches:** missing blank lines around headings/lists, multiple consecutive blank lines, inline HTML, bare URLs, inconsistent formatting.
**Config:** `markdownlint-cli2.jsonc` at repo root — single source of truth, used by both `lint.sh` and the pre-commit hook.

### 10. Checkov (IaC Security)

**Type:** infrastructure compliance scanner.
**Catches:** CIS benchmark violations, public resources, unencrypted storage, missing logging.
**Skips:** `CKV_AWS_260`, `CKV2_AWS_41` — false positives in single-instance setup.

### 11. actionlint (GitHub Actions)

**Type:** GitHub Actions workflow linter.
**Catches:** incorrect `uses:` references, missing permissions, shell injection, deprecated syntax.
**Config:** runs with `-shellcheck="$(command -v shellcheck)"` (pip `shellcheck-py`) — every inline `run:` script in workflows is also checked by shellcheck (the separate ShellCheck job covers standalone `.sh` files).

### 12. yamllint (YAML)

**Type:** generic YAML linter.
**Catches:** syntax errors, indentation, duplicate keys, trailing spaces, inconsistent document markers.
**Config:** `.yamllint.yml` (Jinja templates and vendored dashboards are excluded).

### 13. zizmor (GitHub Actions security)

**Type:** static security analyzer for GitHub Actions.
**Catches:** dangerous triggers, template injection, credential leakage, unpinned actions, excessive permissions.
**Config:** `--min-confidence medium`; findings that are safe by construction carry an inline `# zizmor: ignore[...]` justification.

### 14. Renovate Config Validator (JSON/RegEx)

**Type:** dependency-update config validator.
**Catches:** invalid `renovate.json` schema, broken custom manager regex patterns (e.g. double-slash wrapping after config migration). Run with `npx --yes --package "renovate@$RENOVATE_VERSION" -- renovate-config-validator` (version pinned in ci.yml, bumped by Renovate). See the Renovate section in CLAUDE.md for the `managerFilePatterns` caveat.

### 15. Cloudflare IP ranges

**Type:** data-drift check (not a linter — no static analysis).
**Purpose:** compares the vendored `ansible-roles/nginx/files/cloudflare-realip.conf` against the live `cloudflare.com/ips-v4`/`ips-v6` lists. The Terraform firewalls fetch the same lists at plan time, so a stale vendored copy would silently break real-IP detection.
**Run:** `./scripts/lint.sh --cloudflare-ips` (part of `--fast`; skips when offline).

### 16. Secrets audit

**Type:** repository hygiene check (not a linter).
**Catches:** `secrets/` tracked in git, `.env` files tracked, `.service` files committed instead of `.service.j2`, private keys, tracked `CLAUDE.md`, and common hardcoded-secret patterns.
**Run:** `./scripts/lint.sh --secrets` — CI runs it in the `gitleaks` job alongside the full-history scan.

### 17. Deploy Check

**Type:** orchestration smoke test (not a linter).
**Purpose:** runs the real `deploy.sh -c` (preflight, vault decrypt, `.env` parsing, playbook syntax, Terraform validate) on a push to `main`/`dev`. It is push-only because it loads real secrets and executes PR-modified code — never on pull requests.
**Run:** `./deploy.sh <target> -c` (locally, without `-n` changes).

### 18. Env parser contract (bash + python3)

**Type:** cross-parser behavioral check (not a linter — no static analysis).
**Purpose:** the same `secrets/.env` flows through three independent parsers (`lib/env.sh` on the deploy controller, `common_functions.sh load_env` in server scripts, `env_loader.py` in the telegram bot). This script runs all three against the fixtures in `tests/env/` and asserts identical `KEY=VALUE` output, plus freezes the documented divergences (blocked vars / malformed lines / `ENV=`: lib/env.sh fails loudly, server side skips silently).
**Run:** `./scripts/check_env_contract.sh` — **before editing any of the three parsers**. Zero dependencies (bash + python3); also runs in CI as the `env-contract` job on every PR and push (`ci.yml`).

### 19. terraform-docs (Terraform)

**Type:** documentation generator, run as a pre-commit hook (one per root: aws/hetzner/grafana/cloudflare).
**Purpose:** keeps `terraform/<root>/README.md` in sync with variables/outputs/resources. Gracefully skips when the binary is absent.

### 20. bats (Bash)

**Type:** unit-test runner for shell code (bats-core; version pinned as `BATS_VERSION` in `ci.yml`, Renovate-tracked).
**Scope:** `tests/bats/*.bats` — pure helpers that need no network or cloud: `parse_args`/`resolve_target` (`lib/cli.sh`), `parse_env_file` (`lib/env.sh`), and formatting helpers (`lib/helpers.sh`, `scripts/common_functions.sh`).
**Run:** `make test-bash` or `bats --print-output-on-failure tests/bats`; CI runs it in the `ShellCheck` job. Tests use `$BATS_TEST_TMPDIR` (never a shared `/tmp` path) and assert exit status and output separately.

---

## Tool Mapping

```
PROJECT CODE
├── Bash (.sh)          → ShellCheck (+ pre-commit shebang)
├── Bash tests (.bats)  → bats
├── Python (.py)        → ruff (lint + format)
├── Ansible (.yml)      → ansible-lint
├── Terraform (.tf)     → tflint + terraform validate
│   └── Security        → Trivy + Checkov
├── GitHub Actions      → actionlint
├── Markdown (.md)      → markdownlint-cli2
├── Git history         → gitleaks
└── Commit hooks        → pre-commit
```

- Synced automatically from [docs/](https://github.com/W1ckedS1ck/DreamSeed/tree/main/docs)

---

### Changelog

See [Releases](https://github.com/W1ckedS1ck/DreamSeed/releases).
