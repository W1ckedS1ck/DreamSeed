# Linters in DreamSeed

## Overview

There are 2 layers of linting:

- **Local**: `./deploy.sh --lint` or `./scripts/lint.sh` — fast mode covers ShellCheck, ruff, ansible-lint, actionlint, zizmor, yamllint, Renovate, markdownlint, Cloudflare IPs. Run `./scripts/lint.sh --full --ci` for the full suite (adds tflint, terraform validate, gitleaks, Trivy, secrets audit; `--ci` just adds GitHub annotations)
- **CI on GitHub**: `ci.yml` (11 jobs, 8 required for merge)

---

## All Linters

| # | Tool | Layer | What it checks | Language |
|---|------|-------|----------------|----------|
| 1 | **ShellCheck** | local + CI | `deploy.sh`, `scripts/*.sh`, `.github/scripts/*.sh` | Bash |
| 2 | **ruff** | local | `scripts/telegram_bot.py`, `scripts/env_loader.py` | Python |
| 3 | **ansible-lint** | local + CI | `ansible/playbook-*.yml`, `ansible-roles/*/tasks/*.yml` | YAML/Ansible |
| 4 | **tflint** | local + CI | `terraform/aws/*.tf`, `terraform/hetzner/*.tf`, `terraform/grafana/*.tf` | HCL/Terraform |
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
| 16 | **Secrets audit** | local (full) | `.gitignore` excludes (`secrets/`, `.env`, `*.service`), `secrets/` not tracked in git, required env vars present | Secrets |
| 17 | **Deploy Check** | CI | real `deploy.sh -c` smoke test (env parse, vault, playbook syntax) | orchestration |

---

## Details

### 1. ShellCheck (Bash)

**Type:** static Bash analyzer.
**Catches:** uninitialized variables, `set -e` disabled by `||`, temp file race conditions, incorrect substitutions, quoting issues.
**Example:** `$var` instead of `"$var"` (breaks if value contains spaces).

### 2. ruff (Python)

**Type:** Python linter + formatter (replaces flake8 + isort + pyflakes).
**Catches:** unused imports, syntax errors, naming violations, Python version incompatibility.

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
**Config:** `markdownlint-cli2.jsonc` at repo root (used by `lint.sh`). `.markdownlint.yml` is a legacy copy kept for the pre-commit hook — keep both in sync.

### 10. Checkov (IaC Security)

**Type:** infrastructure compliance scanner.
**Catches:** CIS benchmark violations, public resources, unencrypted storage, missing logging.
**Skips:** `CKV_AWS_260`, `CKV2_AWS_41` — false positives in single-instance setup.

### 11. actionlint (GitHub Actions)

**Type:** GitHub Actions workflow linter.
**Catches:** incorrect `uses:` references, missing permissions, shell injection, deprecated syntax.
**Config:** runs with `-shellcheck="$(command -v shellcheck)"` (pip `shellcheck-py`) — every inline `run:` script in workflows is also checked by shellcheck (the separate ShellCheck job covers standalone `.sh` files).

### 12. Renovate Config Validator (JSON/RegEx)

**Type:** dependency-update config validator.
**Catches:** invalid `renovate.json` schema, broken custom manager regex patterns (e.g. double-slash wrapping after config migration). Run with `npx --yes --package renovate@44 -- renovate-config-validator`. See the Renovate section in CLAUDE.md for the `managerFilePatterns` caveat.

---

## Tool Mapping

```
PROJECT CODE
├── Bash (.sh)          → ShellCheck (+ pre-commit shebang)
├── Python (.py)        → ruff
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

### Last updated: 2026-08-18
