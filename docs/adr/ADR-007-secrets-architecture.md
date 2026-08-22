# ADR-007: Secrets architecture

- **Status:** Accepted
- **Amended:** 2026-06 — after a tfvars leak was purged from history

## Context

One repo drives four Terraform roots, nine Ansible playbooks, ten CI workflows, and server-side scripts. Secrets must flow to each consumer without copies drifting or leaking into git, CI logs, process lists, or servers that do not need them.

## Decision

Three stores with strict roles:

1. **`secrets/.env` (Ansible Vault)** — single source of truth for human-driven work locally; decrypted only in memory, temp files shredded
2. **GitHub Encrypted Secrets** — source of truth for CI; workflows read `secrets.*`, never the vault copy (copies drift)
3. **Servers get a whitelist** — `server.env.j2` renders only variables server-side scripts need; cloud credentials architecturally cannot reach web servers

Hygiene rules:

- Tokens never appear in argv: `curl --config <(_bearer_auth ...)` everywhere, verified by grep in review and lint
- `terraform.tfvars` are vault-encrypted and gitignored; `.terraform.lock.hcl` files are committed
- Gitleaks scans staged changes (pre-commit) and full history (CI) with checksum-verified pinned binary; custom rules cover project token formats

## Incident note

June 2026: `terraform.tfvars` with a real token was committed once and purged via `git-filter-repo`. The incident is documented in `.gitleaksignore` rather than hidden; the scanning stack above exists largely because of it.
