# ADR-004: MODX sessions on Redis via the PHP native handler

- **Status:** Accepted
- **Amended:** 2026-08 — hardening after audit found a silent failure path

## Context

MODX writes PHP sessions to the database by default, which makes every authenticated request hit MariaDB and bloats the session table. MODX also supports a custom `session_handler_class`, but that couples the CMS to a bespoke class that must be deployed and upgraded with core.

## Decision

Leave `session_handler_class` **empty** in system settings: MODX then falls through to PHP's native session save handler, which points at Redis. The setting is force-cleared on every deploy (backup role) and every restore (restore role), because restored DB snapshots resurrect the old value.

## Consequences

- Sessions live in Redis with TTL semantics; the DB keeps no session rows
- The clearing step is load-bearing, not cosmetic: an unquoted reserved word (`WHERE key = ...`) in the restore role once silenced this fix entirely behind `2>/dev/null || true`. The task now uses `ansible.mariadb.mariadb_query` with properly quoted identifiers, and the weekly DR test asserts the value is empty — a regression fails the pipeline instead of hiding
