# ADR-003: Dev mirrors Prod everywhere

- **Status:** Accepted

## Context

Common failure mode of two-environment setups: dev accumulates "skip it for dev" logic until dev no longer predicts prod behavior. Then every prod deploy is the first real test.

## Decision

There is **no "skip for dev" logic anywhere in the codebase**. Dev environments get the same monitoring stack, alerting, backup schedules with cloud upload (separate paths), fail2ban, SSL handling, and check scripts as prod. Dev is ephemeral and can be re-seeded from prod data via the restore pipeline.

## Consequences

- Slightly higher running cost for dev — bought certainty that every mechanism is exercised continuously
- Playbooks contain zero conditional shortcuts, which keeps them auditable
- Drift detection and health checks run identically across environments, so breakage is caught in dev hours before it would reach prod
