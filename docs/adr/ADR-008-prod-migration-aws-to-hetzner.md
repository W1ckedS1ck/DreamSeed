# ADR-008: Production migration from AWS to Hetzner Cloud

- **Status:** Accepted
- **Date:** 2026-08-21

## Context

DreamSeed ran production on AWS (EC2 `t3.small`, `us-west-1`) from inception.
The AWS workspace held a single `prod` environment under `terraform/aws/`.
Hetzner Cloud was added later (`terraform/hetzner/`) for dev environments,
and the comparison quickly revealed meaningful gaps:

- **Cost** — Hetzner `cx33` (4 GB / 2 vCPU / 40 GB NVMe) is ~3× cheaper per
  month than an equivalent EC2 instance once egress and snapshot charges
  are factored in. Dev environments were already on Hetzner, so the
  production-only AWS bill was a single-environment premium.
- **Single-vendor drift** — `terraform/aws/` and `terraform/hetzner/` were
  provider-split roots by design (ADR-001) but prod-vs-dev split meant two
  live workspaces, two backup pipelines, and two mental models.
- **Cloudflare-only ingress** (ADR-005) is provider-agnostic, so the
  migration does not weaken the WAF posture: edge rules are zone-scoped
  and apply regardless of where the origin lives.

## Decision

On 2026-08-21 the production environment was migrated to Hetzner:

- `hcloud_server.main` provisioned with `delete_protection = true` and
  `rebuild_protection = true` for `prod-hetz` (the prod-via-hetzner workspace).
- `hcloud_primary_ip.main` reused the existing elastic-IP analogue with
  `delete_protection = true` so the Cloudflare A record remained stable
  during the cutover.
- The DNS A record for `dreamseed.online` was repointed from the AWS
  public IP to the Hetzner public IP via Cloudflare's API (the same path
  `update_cloudflare_dns` uses for normal deploys).
- `terraform/aws/` was left intact for `dev-aws` (the lower-cost test bed),
  but the `prod` AWS workspace is dormant — no `prod` deploys go through
  it.

## Consequences

- Single live prod workspace (`prod-hetz`) instead of two parallel prod
  environments on different providers. Drift surface halved.
- `terraform/aws/main.tf:157` keeps `disable_api_termination` for any
  accidental `prod` workspace re-activation, but does not have
  `prevent_destroy` (Terraform 1.11+ rejects variables in `lifecycle`;
  see ADR-002 for the explicit decision).
- Dev-hetz → prod-hetz backup pipeline is now uniform: same `rclone lsf`
  listing, same `gdrive-crypt` remote, same restore flow. Dev restores
  prod backups by design (no separate dev pipeline — see
  `ansible/group_vars/all.yml` comments).
- The AWS prod credentials (`PROD_AWS_*`) live in GitHub Secrets only
  for the legacy `prod` AWS workspace and are never read by the
  `prod-hetz` deploy path. The dormant AWS root serves as a documented
  rollback target (re-point DNS, re-apply) but is not maintained.
- A future migration to a third provider would be a smaller change now:
  the `terraform/{provider}/` directory layout, `TARGET_PREFIX` env
  mapping, and deploy orchestration already abstract the choice.
