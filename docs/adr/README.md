# Architecture Decision Records

Short, immutable records of significant infrastructure decisions. Each ADR captures the context, the decision, and its consequences — the "why" behind the code.

| # | Decision | Status |
|---|----------|--------|
| [001](ADR-001-provider-split-roots.md) | Provider-split Terraform roots instead of a shared abstraction | Accepted |
| [002](ADR-002-tfc-state-backend.md) | Terraform Cloud as the only state backend | Accepted |
| [003](ADR-003-dev-equals-prod.md) | Dev mirrors Prod everywhere | Accepted |
| [004](ADR-004-redis-sessions.md) | MODX sessions on Redis via the PHP native handler | Accepted |
| [005](ADR-005-cloudflare-only-ingress.md) | Cloudflare-only ingress to origins | Accepted |
| [006](ADR-006-weekly-dr-rehearsal.md) | Weekly automated DR rehearsal | Accepted |
| [007](ADR-007-secrets-architecture.md) | Secrets architecture | Accepted |

New ADRs get the next sequential number and never overwrite existing ones; superseded decisions are marked as such, not deleted.
