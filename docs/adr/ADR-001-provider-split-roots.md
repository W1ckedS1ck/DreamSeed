# ADR-001: Provider-split Terraform roots instead of a shared abstraction

- **Status:** Accepted
- **Date:** 2026-08 (retrospective; decision made during the AWS → Hetzner migration)

## Context

Production started on AWS EC2 and migrated to Hetzner Cloud in August 2026. Both providers must remain deployable: Hetzner runs prod, AWS stays available as a fallback environment. The two stacks share ~80% of their intent (one server, firewall, edge DNS) but differ in provider APIs, instance semantics, and lifecycle protections.

## Decision

Keep `terraform/aws/` and `terraform/hetzner/` as **independent root configurations** with shared conventions (naming, tagging, variable contracts) instead of extracting a common "web-server" module.

## Consequences

- ~30 lines of duplication (e.g. Cloudflare IP-range data sources) — accepted, reviewed on change
- No leaky abstraction: each root uses its provider idiomatically (`disable_api_termination` on AWS, `delete_protection` + `rebuild_protection` on Hetzner)
- A third provider would be the trigger to extract real modules; until then an abstraction layer would cost more than the duplication it removes
