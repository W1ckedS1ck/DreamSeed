# ADR-006: Weekly automated DR rehearsal

- **Status:** Accepted

## Context

Backups that have never been restored are Schrödinger's backups. Manual disaster-recovery drills are the classic "quarterly task" that silently stops happening.

## Decision

A scheduled GitHub Actions workflow (`test-restore.yml`) runs the full DR cycle **every week against an ephemeral Hetzner server**:

1. Deploy a fresh server from scratch
2. Take a real backup (project + DB + Redis)
3. Simulate disaster (wipe local state)
4. Restore via both paths: local artifacts and cloud (Google Drive) — the same `RESTORE_ALL.sh` a human would run at 3 a.m.
5. Run 60+ service assertions (web, DB, Redis sessions, SSL, exporters, cron, logs)
6. Destroy the server

## Consequences

- RTO < 5 min is a number proven by a robot weekly, not a claim in a runbook
- Restore regressions surface in CI, not during an actual outage (this is exactly how the silent SQL bug in the restore role was made visible and fixed)
- Costs one small server for ~30 minutes per week — negligible against the confidence it buys
- Alternatives considered: manual quarterly drills (rejected — humans forget), restore tests inside prod (rejected — blast radius)
