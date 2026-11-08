# GitHub Posture

Server-side monitoring is covered by VictoriaMetrics + 28 Grafana alert rules.
**GitHub itself was the blind spot** — the only path through which
infrastructure can change. This page documents the repo-side audit that closes
it: [`scripts/github_posture.py`](https://github.com/W1ckedS1ck/DreamSeed/blob/main/scripts/github_posture.py) and the
[GitHub Posture workflow](https://github.com/W1ckedS1ck/DreamSeed/blob/main/.github/workflows/github-posture.yml).

The audit is **read-only**. It never writes to the repository and never prints
secret material — only alert metadata (type, count, URL).

## What it checks

| Check | What "green" means |
|-------|--------------------|
| `secret_scanning` | No open secret scanning alerts |
| `dependabot` | No open Dependabot alerts (grouped by severity) |
| `code_scanning` | No open code scanning alerts (grouped by severity) |
| `security_settings` | Secret scanning, push protection and Dependabot security updates are on |
| `ruleset` | The default-branch ruleset is active, has no bypass actors, blocks deletion/force-push, requires PRs, its required checks match `ci.yml`, and its policy matches the committed `.github/rulesets/protect-main.json` |
| `actions` | Default token is read-only, PR approval is off, SHA pinning is required |
| `scorecard` | OpenSSF Scorecard is at least 7.0 |
| `config` | Every input the audit compares against (`ci.yml`, the ruleset file) could be read |

### Ruleset as code

`.github/rulesets/protect-main.json` is the committed policy for `Protect Main`
(IDs and timestamps stripped). The audit diffs the live ruleset against it, so a
bypass actor or a weakened rule added in the GitHub UI shows up as a **high**
finding, even if the required check names still match `ci.yml`.

Changing the ruleset on purpose is a PR: update the JSON in the same change.
When you add a CI job, update the file's `required_status_checks` too (CLAUDE.md
already requires the ruleset change; the file is the place it lives in git).
Regenerate it from the live ruleset with `gh api repos/<repo>/rulesets/<id>`
and `ruleset_snapshot()` from `scripts/github_posture.py`, so the normalisation
matches.

### Failure semantics

- A **403** or network error on a lookup is a `medium` finding, not a
  "missing protection" alarm. Only a real **404** means no ruleset exists.
- An input that cannot be read (`ci.yml` does not parse, `pip install` failed
  and `pyyaml` is missing, the ruleset file is malformed) becomes a `medium`
  `config` finding. The check it feeds is never silently dropped.

Secret scanning validity checks and non-provider patterns are reported as
**notes**, not findings: they require paid GitHub Secret Protection, so
flagging them would nag forever.

## Alerting model

Telegram is noisy by nature, so the workflow sends **only changes**:

1. The report is cached (`.posture-cache/github-posture.json`).
2. Each finding has a stable fingerprint (`check:key:severity`), not the
   message text — a Dependabot group going from 2 to 3 alerts is the same
   finding, and does not re-notify.
3. The next run compares against the cached report and sends:
   - new findings, with severity icons;
   - resolved findings, so a fix is acknowledged;
   - nothing at all when the posture is unchanged.

The full report always lands in the job summary and as a build artifact, even
when nothing is sent.

### Dead-man's switch

A failed run already notifies Telegram, but a run that never starts (the cron
did not fire, the workflow was disabled) notifies nothing. So a successful audit
pings a Better Stack heartbeat (`POSTURE_HEARTBEAT_KEY`). If the ping stops
arriving, Better Stack alerts. The ping is skipped on crashes, so a broken audit
looks like silence and trips the same alarm.

Setup (once): create a heartbeat in Better Stack with a period of about 26 hours
(the cron is daily), then store its key as the `POSTURE_HEARTBEAT_KEY` Actions
secret. Without the secret, the step is a no-op.

## Running locally

```bash
# Markdown to stdout (uses GH_TOKEN / GITHUB_TOKEN)
GH_TOKEN="$(gh auth token)" python3 scripts/github_posture.py \
  --repo W1ckedS1ck/DreamSeed \
  --ci-workflow .github/workflows/ci.yml

# All renderings + baseline diff
GH_TOKEN="$(gh auth token)" python3 scripts/github_posture.py \
  --repo W1ckedS1ck/DreamSeed \
  --ci-workflow .github/workflows/ci.yml \
  --write-dir /tmp/posture \
  --baseline /tmp/previous/github-posture.json

# Prometheus text (for Grafana)
... --format prometheus

# Exit 3 when something critical/high is open (1 = crash, 0 = clean or below threshold)
... --fail-on high
```

Useful flags: `--expected-checks`, `--ruleset`, `--ruleset-file`, `--no-scorecard`,
`--telegram-on {findings,always,never}`, `--format {markdown,json,prometheus,telegram}`.

Exit codes: `0` ok, `3` `--fail-on` threshold breached, anything else is a real
crash. The workflow runs the threshold check as its very last step, so a breach
fails the run only after the summary, Telegram, baseline cache and heartbeat.

## Tokens

`GITHUB_TOKEN` with `security-events: read` reads **code scanning** alerts.
The other security endpoints are separate permissions that `GITHUB_TOKEN`
does not have:

| Data | Needs |
|------|-------|
| Secret scanning alerts | Secret scanning alerts: read |
| Dependabot alerts | Dependabot alerts: read |
| Actions policy | Administration: read |

`vulnerability-alerts` is not yet known to actionlint 1.7.12, so declaring it
would fail the required lint check. The audit therefore **reports HTTP 403 as
a `medium` finding** instead of silently skipping it — a blind security check
is worse than a noisy one. `404` (feature disabled or unavailable on the plan)
is recorded as a note.

To get full coverage, create a **fine-grained PAT** scoped to this repository
with read-only access to *Secret scanning alerts*, *Dependabot alerts* and
*Administration*, and store it as the `POSTURE_TOKEN` secret. The workflow
prefers it automatically; without it, code scanning, rulesets, settings and
Scorecard still work.

## Metrics (not wired yet)

`--format prometheus` already emits the metrics below. Getting them into Grafana
is **not done**, and the route is a real decision:

- The `github_posture_*` metrics would have to reach **Grafana Cloud**, because
  the workflow runs on GitHub, not on the prod box.
- The existing alert rules (`ansible-roles/grafana/templates/grafana-alerts.yaml.j2`)
  query only the local `VictoriaMetrics` datasource. A Cloud-side alert needs its
  own datasource and provisioning, not a one-line rule.

Options: (a) remote-write from the workflow into Grafana Cloud plus a
Cloud-managed alert; (b) keep Telegram + the heartbeat as the alerting path and
skip Grafana for this signal. The metrics format:

```text
github_posture_findings{severity="critical"} 0
github_posture_check_ok{check="ruleset"} 1
github_posture_check_findings{check="code_scanning"} 3
github_posture_scorecard_score 7.4
github_posture_last_run_timestamp 1760000000
```

The natural next step is pushing these to VictoriaMetrics (or Grafana Cloud)
and adding an alert rule for `github_posture_findings{severity=~"critical|high"} > 0`,
so GitHub posture appears next to the server alerts.

## Adding a check

1. Write `check_<name>(github, repo)` returning `(status, findings, notes)`.
2. Give every finding a **stable `key`** — it is the diff identity across runs.
3. Register it in `collect()`.
4. Add a fixture-driven test in `tests/unit/test_github_posture.py`.
