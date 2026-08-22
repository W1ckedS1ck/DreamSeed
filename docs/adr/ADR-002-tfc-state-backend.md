# ADR-002: Terraform Cloud as the only state backend

- **Status:** Accepted

## Context

Four Terraform root configurations (aws, hetzner, cloudflare, grafana) manage production resources across environments. State files contain everything needed to reconstruct — and to destroy — the infrastructure.

## Decision

All roots use the **Terraform Cloud remote backend** with one workspace per environment: state lives off-box with built-in locking, and no operator laptop ever holds authoritative state. As a belt-and-suspenders measure, state backups are pulled and **Ansible-Vault-encrypted** into `secrets/tfstate-backup/` on every deploy.

## Consequences

- Concurrent runs cannot corrupt state (remote locking); the deploy script also takes a provider-level lock to serialize Terraform and Ansible phases
- TFC's quirk of returning exit code 1 after a successful destroy is handled explicitly in the deploy pipeline (grep for `Destroy complete`)
- SaaS dependency is accepted; the encrypted local backups double as the documented escape hatch (`terraform state push` path in `lib/provision.sh`)
