"""Read-only GitHub posture audit for the DreamSeed repository.

The server stack is watched by VictoriaMetrics + 28 alert rules, but GitHub
itself — the only path through which infrastructure can change — was not.
This script closes that gap. It answers four questions:

  1. Are there open security alerts (secret scanning, Dependabot, code scanning)?
  2. Are the repository security switches still on?
  3. Is the ruleset protecting the default branch active, bypass-free and in
     sync with the required checks declared in ci.yml?
  4. Is GitHub Actions still hardened (read-only token, SHA pinning)?

Secret material is never printed: only alert metadata (type, count, URL).
Everything is read-only, so it is safe to run on a schedule.

Outputs: Markdown (job summary), JSON, Prometheus text, Telegram HTML.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

API = "https://api.github.com"
SCORECARD_API = "https://api.securityscorecards.dev/projects/github.com/{repo}"
API_VERSION = "2022-11-28"
PER_PAGE = 100
CI_WORKFLOW = ".github/workflows/ci.yml"
RULESET_FILE = ".github/rulesets/protect-main.json"
EXIT_THRESHOLD = 3

SEVERITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
SEVERITY_ICON = {
    "critical": "🔴",
    "high": "🟠",
    "medium": "🟡",
    "low": "🔵",
    "info": "⚪",
}
STATUS_ICON = {"ok": "✅", "warn": "⚠️", "fail": "❌", "skipped": "➖"}

# Accept both GitHub's advisory wording and code-scanning rule severities.
SEVERITY_ALIASES = {
    "critical": "critical",
    "high": "high",
    "error": "high",
    "moderate": "medium",
    "medium": "medium",
    "warning": "medium",
    "low": "low",
    "note": "info",
}


@dataclass(frozen=True)
class Finding:
    """One actionable problem. `detail` never contains secret values."""

    check: str
    severity: str
    title: str
    detail: str = ""
    url: str | None = None
    key: str = "generic"

    @property
    def fingerprint(self) -> str:
        """Stable identity across runs: counts may change, the category may not."""
        return f"{self.check}:{self.key}:{self.severity}"


@dataclass
class Report:
    repo: str
    generated_at: str
    checks: dict[str, str] = field(default_factory=dict)
    findings: list[Finding] = field(default_factory=list)
    scorecard: float | None = None
    notes: list[str] = field(default_factory=list)
    # Checks whose data could not be read this run. Their previous findings
    # must never be reported as resolved.
    unavailable: set[str] = field(default_factory=set)

    @property
    def counts(self) -> dict[str, int]:
        counts = {sev: 0 for sev in SEVERITY_RANK}
        for finding in self.findings:
            counts[finding.severity] = counts.get(finding.severity, 0) + 1
        return counts

    @property
    def total(self) -> int:
        return len(self.findings)

    def sorted_findings(self) -> list[Finding]:
        return sorted(
            self.findings,
            key=lambda f: (SEVERITY_RANK.get(f.severity, 9), f.check, f.title),
        )


class GitHub:
    """Tiny GitHub REST client with token, fallback-token and anonymous modes."""

    def __init__(
        self,
        token: str | None = None,
        fallback: str | None = None,
        timeout: int = 20,
    ) -> None:
        # POSTURE_TOKEN may be narrower than GITHUB_TOKEN (e.g. no Code
        # scanning alerts read). Try the primary token, then the fallback,
        # then anonymous — a missing scope must not blind a check that the
        # other token can read.
        self.tokens = [t for t in (token, fallback) if t]
        self.timeout = timeout

    def get(self, path_or_url: str) -> tuple[int, object | None]:
        url = path_or_url if path_or_url.startswith("http") else API + path_or_url
        status: int = 0
        data: object | None = None
        for token in [*self.tokens, None]:
            status, data = self._request(url, token)
            if status == 200:
                return status, data
            if status not in (401, 403, 404):
                return status, data
        return status, data

    def get_public(self, url: str) -> tuple[int, object | None]:
        """Fetch a non-GitHub API (Scorecard) without GitHub headers or token."""
        return self._request(url, None, github=False)

    def _request(
        self, url: str, token: str | None, github: bool = True
    ) -> tuple[int, object | None]:
        headers = {"User-Agent": "dreamseed-github-posture"}
        if github:
            headers["Accept"] = "application/vnd.github+json"
            headers["X-GitHub-Api-Version"] = API_VERSION
        else:
            # Scorecard returns 406 for the GitHub media type.
            headers["Accept"] = "application/json"
        req = urllib.request.Request(url, headers=headers)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, json.load(resp)
        except urllib.error.HTTPError as exc:
            body: object | None = None
            try:
                body = json.load(exc)
            except (ValueError, OSError):
                pass
            return exc.code, body
        except (urllib.error.URLError, TimeoutError, OSError):
            return 0, None


def _severity(value: object) -> str:
    return SEVERITY_ALIASES.get(str(value or "").lower(), "medium")


def _status_for(findings: list[Finding]) -> str:
    if any(f.severity in ("critical", "high") for f in findings):
        return "fail"
    if findings:
        return "warn"
    return "ok"


def _group(items: list[dict], key: str) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for item in items:
        grouped.setdefault(str(item.get(key) or "unknown"), []).append(item)
    return grouped


def check_secret_scanning(github: GitHub, repo: str) -> tuple[str, list[Finding], list[str]]:
    status, alerts = github.get(
        f"/repos/{repo}/secret-scanning/alerts?state=open&per_page={PER_PAGE}"
    )
    if status == 403:
        # Secret scanning alerts are their own permission; GITHUB_TOKEN does
        # not have it. Do not go quiet about that — a blind audit is worse
        # than a noisy one.
        findings = [
            Finding(
                check="secret_scanning",
                severity="medium",
                title="Secret scanning alerts are unreadable with the current token",
                detail="Add a POSTURE_TOKEN secret with Secret scanning alerts: read, "
                "otherwise leaked credentials stay invisible to this audit.",
                url=f"https://github.com/{repo}/settings/secrets/actions",
                key="secret_scanning:token",
            )
        ]
        return _status_for(findings), findings, ["secret scanning alerts unreadable (HTTP 403)"]
    if status != 200 or not isinstance(alerts, list):
        return "skipped", [], [f"secret scanning alerts unreadable (HTTP {status})"]

    findings: list[Finding] = []
    notes: list[str] = []
    statuses = _group(alerts, "secret_type_display_name")
    for secret_type, group in sorted(statuses.items()):
        findings.append(
            Finding(
                check="secret_scanning",
                severity="critical",
                title=f"Secret scanning: {len(group)} open {secret_type} alert(s)",
                detail="Revoke the credential at the provider, rotate it, then "
                "resolve the alert. Never paste the value anywhere.",
                url=f"https://github.com/{repo}/security/secret-scanning",
                key=f"secret:{secret_type}",
            )
        )
    if len(alerts) == PER_PAGE:
        notes.append("secret scanning returned a full page — more alerts may exist")
    return _status_for(findings), findings, notes


def check_dependabot(github: GitHub, repo: str) -> tuple[str, list[Finding], list[str]]:
    status, alerts = github.get(
        f"/repos/{repo}/dependabot/alerts?state=open&per_page={PER_PAGE}"
    )
    if status == 403:
        findings = [
            Finding(
                check="dependabot",
                severity="medium",
                title="Dependabot alerts are unreadable with the current token",
                detail="Add a POSTURE_TOKEN secret with Dependabot alerts: read, "
                "otherwise vulnerable dependencies stay invisible to this audit.",
                url=f"https://github.com/{repo}/settings/secrets/actions",
                key="dependabot:token",
            )
        ]
        return _status_for(findings), findings, ["Dependabot alerts unreadable (HTTP 403)"]
    if status != 200 or not isinstance(alerts, list):
        return "skipped", [], [f"Dependabot alerts unreadable (HTTP {status})"]

    findings: list[Finding] = []
    # The advisory severity lives one level down from the alert.
    by_severity: dict[str, list[dict]] = {}
    for alert in alerts:
        advisory = alert.get("security_advisory") or {}
        sev = _severity(advisory.get("severity"))
        by_severity.setdefault(sev, []).append(alert)

    for sev in sorted(by_severity, key=lambda s: SEVERITY_RANK[s]):
        group = by_severity[sev]
        packages = sorted(
            {
                str((((a.get("dependency") or {}).get("package")) or {}).get("name"))
                for a in group
            }
            - {"None"}
        )
        findings.append(
            Finding(
                check="dependabot",
                severity=sev,
                title=f"Dependabot: {len(group)} open {sev}-severity alert(s)",
                detail="Packages: " + ", ".join(packages[:8])
                if packages
                else "No package metadata returned.",
                url=f"https://github.com/{repo}/security/dependabot",
                key="alerts",
            )
        )
    return _status_for(findings), findings, []


def check_code_scanning(github: GitHub, repo: str) -> tuple[str, list[Finding], list[str]]:
    status, alerts = github.get(
        f"/repos/{repo}/code-scanning/alerts?state=open&per_page={PER_PAGE}"
    )
    if status == 403:
        findings = [
            Finding(
                check="code_scanning",
                severity="medium",
                title="Code scanning alerts are unreadable with the current token",
                detail="POSTURE_TOKEN needs Code scanning alerts: read, or the "
                "workflow must grant security-events: read to GITHUB_TOKEN.",
                url=f"https://github.com/{repo}/settings/secrets/actions",
                key="code_scanning:token",
            )
        ]
        return _status_for(findings), findings, ["code scanning alerts unreadable (HTTP 403)"]
    if status != 200 or not isinstance(alerts, list):
        return "skipped", [], [f"code scanning alerts unreadable (HTTP {status})"]

    by_severity: dict[str, list[dict]] = {}
    for alert in alerts:
        rule = alert.get("rule") or {}
        sev = _severity(rule.get("security_severity_level") or rule.get("severity"))
        by_severity.setdefault(sev, []).append(alert)

    findings: list[Finding] = []
    for sev in sorted(by_severity, key=lambda s: SEVERITY_RANK[s]):
        group = by_severity[sev]
        rules = sorted({str((a.get("rule") or {}).get("id") or "unknown") for a in group})
        findings.append(
            Finding(
                check="code_scanning",
                severity=sev,
                title=f"Code scanning: {len(group)} open {sev}-severity alert(s)",
                detail="Rules: " + ", ".join(rules[:8]),
                url=f"https://github.com/{repo}/security/code-scanning",
                key="alerts",
            )
        )
    return _status_for(findings), findings, []


def check_security_settings(
    repo: str, repo_data: dict
) -> tuple[str, list[Finding], list[str]]:
    analysis = repo_data.get("security_and_analysis") or {}
    notes: list[str] = []
    if not analysis:
        # Unauthenticated responses (and tokens without metadata access) omit
        # this block entirely. Never turn "unknown" into "disabled".
        return (
            "skipped",
            [],
            ["security settings unavailable — security_and_analysis is missing"],
        )

    def switch(name: str) -> str:
        return str((analysis.get(name) or {}).get("status") or "")

    findings: list[Finding] = []
    required = (
        ("secret_scanning", "high", "Secret scanning is disabled"),
        (
            "secret_scanning_push_protection",
            "high",
            "Secret scanning push protection is disabled",
        ),
        (
            "dependabot_security_updates",
            "medium",
            "Dependabot security updates are disabled",
        ),
    )
    for name, severity, title in required:
        state = switch(name)
        if not state:
            notes.append(f"{name} state unavailable")
            continue
        if state != "enabled":
            findings.append(
                Finding(
                    check="security_settings",
                    severity=severity,
                    title=title,
                    detail=f"{name} = {state}",
                    url=f"https://github.com/{repo}/settings/security_analysis",
                    key=f"setting:{name}",
                )
            )

    # These two are part of paid GitHub Secret Protection. Reporting them as
    # findings would nag forever on the current plan, so record them as notes.
    for name, label in (
        ("secret_scanning_validity_checks", "validity checks"),
        ("secret_scanning_non_provider_patterns", "non-provider patterns"),
    ):
        if switch(name) != "enabled":
            notes.append(f"secret scanning {label} not enabled (needs GitHub Secret Protection)")

    return _status_for(findings), findings, notes


def _pick_ruleset(
    github: GitHub, repo: str, preferred: str | None
) -> tuple[dict | None, int]:
    """Return (ruleset, 200) or (None, status). 404 only means "no such ruleset"."""
    status, rulesets = github.get(f"/repos/{repo}/rulesets")
    if status != 200 or not isinstance(rulesets, list):
        return None, status

    candidates = [r for r in rulesets if r.get("target") == "branch"]
    candidates = [r for r in candidates if r.get("id") is not None]
    candidates.sort(key=lambda r: r.get("name") != preferred)
    last_status = 404
    for ruleset in candidates:
        detail_status, detail = github.get(f"/repos/{repo}/rulesets/{ruleset['id']}")
        if detail_status != 200 or not isinstance(detail, dict):
            last_status = detail_status
            continue
        if preferred and ruleset.get("name") == preferred:
            return detail, 200
        include = (
            ((detail.get("conditions") or {}).get("ref_name") or {}).get("include")
            or []
        )
        if "~DEFAULT_BRANCH" in include:
            return detail, 200
    return None, last_status


def ruleset_snapshot(detail: dict) -> dict:
    """The part of a ruleset that is policy. IDs, timestamps and links are dropped."""
    rules = []
    for rule in detail.get("rules") or []:
        entry: dict = {"type": rule.get("type")}
        if "parameters" in rule:
            entry["parameters"] = rule["parameters"]
        rules.append(entry)
    rules.sort(key=lambda r: json.dumps(r, sort_keys=True))
    return {
        "name": detail.get("name"),
        "target": detail.get("target"),
        "enforcement": detail.get("enforcement"),
        "conditions": detail.get("conditions"),
        "bypass_actors": detail.get("bypass_actors") or [],
        "rules": rules,
    }


def load_expected_ruleset(path: str) -> dict:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise TypeError("ruleset file must contain a JSON object")
    return payload


def check_ruleset_drift(detail: dict, expected: dict, url: str) -> list[Finding]:
    live = ruleset_snapshot(detail)
    changed = sorted(k for k in live if live[k] != expected.get(k))
    if not changed:
        return []
    return [
        Finding(
            check="ruleset",
            severity="high",
            title=f"Ruleset {live['name']} differs from its committed definition",
            detail="Changed: " + ", ".join(changed)
            + ". Revert it in GitHub, or update .github/rulesets/protect-main.json in a PR.",
            url=url,
            key="ruleset:drift",
        )
    ]


def check_ruleset(
    github: GitHub,
    repo: str,
    expected_checks: set[str] | None,
    preferred_name: str | None,
    expected_ruleset: dict | None = None,
) -> tuple[str, list[Finding], list[str]]:
    detail, status = _pick_ruleset(github, repo, preferred_name)
    url = f"https://github.com/{repo}/rules"
    if detail is None:
        if status == 404:
            return (
                "fail",
                [
                    Finding(
                        check="ruleset",
                        severity="critical",
                        title="No branch ruleset protects the default branch",
                        detail="Ruleset lookup returned HTTP 404.",
                        url=url,
                        key="ruleset:missing",
                    )
                ],
                [],
            )
        # 403 (token scope) or 0 (network): we could not look, which is not
        # the same as "no protection". Say so without crying critical.
        findings = [
            Finding(
                check="ruleset",
                severity="medium",
                title="Branch rulesets are unreadable with the current token",
                detail=f"Ruleset lookup returned HTTP {status}; the protection was not evaluated.",
                url=url,
                key="ruleset:unreadable",
            )
        ]
        return _status_for(findings), findings, [f"rulesets unreadable (HTTP {status})"]

    name = str(detail.get("name") or "unnamed")
    findings: list[Finding] = []

    if detail.get("enforcement") != "active":
        findings.append(
            Finding(
                check="ruleset",
                severity="critical",
                title=f"Ruleset {name} is not enforced",
                detail=f"enforcement = {detail.get('enforcement')}",
                url=url,
                key="ruleset:enforced",
            )
        )

    bypass = detail.get("bypass_actors") or []
    if bypass:
        actors = ", ".join(
            f"{a.get('actor_type')}:{a.get('actor_id')}" for a in bypass
        )
        findings.append(
            Finding(
                check="ruleset",
                severity="high",
                title=f"Ruleset {name} has {len(bypass)} bypass actor(s)",
                detail=actors,
                url=url,
                key="ruleset:bypass",
            )
        )

    rules = {str(r.get("type")) for r in detail.get("rules") or []}
    for rule, severity, label in (
        ("deletion", "high", "branch deletion"),
        ("non_fast_forward", "high", "force pushes"),
        ("pull_request", "medium", "pull requests"),
    ):
        if rule not in rules:
            findings.append(
                Finding(
                    check="ruleset",
                    severity=severity,
                    title=f"Ruleset {name} does not block {label}",
                    detail=f"missing rule: {rule}",
                    url=url,
                    key=f"ruleset:{rule}",
                )
            )

    if expected_checks is not None:
        required: set[str] = set()
        for rule in detail.get("rules") or []:
            if rule.get("type") == "required_status_checks":
                contexts = (rule.get("parameters") or {}).get("required_status_checks") or []
                required = {str(c.get("context")) for c in contexts}
        missing = expected_checks - required
        stale = required - expected_checks
        if missing:
            findings.append(
                Finding(
                    check="ruleset",
                    severity="high",
                    title=f"{len(missing)} CI job(s) are not required on {name}",
                    detail="Missing: " + ", ".join(sorted(missing)),
                    url=url,
                    key="ruleset:required-checks",
                )
            )
        if stale:
            findings.append(
                Finding(
                    check="ruleset",
                    severity="low",
                    title=f"{len(stale)} required check(s) no longer exist in ci.yml",
                    detail="Stale: " + ", ".join(sorted(stale)),
                    url=url,
                    key="ruleset:stale-checks",
                )
            )

    if expected_ruleset is not None:
        findings.extend(check_ruleset_drift(detail, expected_ruleset, url))

    return _status_for(findings), findings, []


def check_actions_policy(
    github: GitHub, repo: str
) -> tuple[str, list[Finding], list[str]]:
    findings: list[Finding] = []
    notes: list[str] = []
    readable = 0
    url = f"https://github.com/{repo}/settings/actions"

    status, workflow = github.get(f"/repos/{repo}/actions/permissions/workflow")
    if status == 200 and isinstance(workflow, dict):
        readable += 1
        if workflow.get("default_workflow_permissions") != "read":
            findings.append(
                Finding(
                    check="actions",
                    severity="medium",
                    title="Default GITHUB_TOKEN permissions are not read-only",
                    detail=(
                        "default_workflow_permissions = "
                        f"{workflow.get('default_workflow_permissions')}"
                    ),
                    url=url,
                    key="actions:token-permissions",
                )
            )
        if workflow.get("can_approve_pull_request_reviews"):
            findings.append(
                Finding(
                    check="actions",
                    severity="medium",
                    title="GITHUB_TOKEN can approve pull requests",
                    detail="can_approve_pull_request_reviews = true",
                    url=url,
                    key="actions:pr-approval",
                )
            )
    else:
        notes.append(f"workflow permissions unreadable (HTTP {status})")

    status, permissions = github.get(f"/repos/{repo}/actions/permissions")
    if status == 200 and isinstance(permissions, dict):
        readable += 1
        if permissions.get("sha_pinning_required") is not True:
            findings.append(
                Finding(
                    check="actions",
                    severity="medium",
                    title="GitHub Actions do not require SHA-pinned actions",
                    detail="sha_pinning_required = false",
                    url=url,
                    key="actions:sha-pinning",
                )
            )
    else:
        notes.append(f"Actions permissions unreadable (HTTP {status})")

    if readable == 0:
        return "skipped", findings, notes
    return _status_for(findings), findings, notes


def check_scorecard(github: GitHub, repo: str) -> tuple[str, list[Finding], list[str], float | None]:
    status, data = github.get_public(SCORECARD_API.format(repo=repo))
    if status != 200 or not isinstance(data, dict) or data.get("score") is None:
        return "skipped", [], [f"OpenSSF Scorecard unavailable (HTTP {status})"], None

    try:
        score = float(data["score"])
    except (TypeError, ValueError):
        return "skipped", [], ["OpenSSF Scorecard returned a non-numeric score"], None

    findings: list[Finding] = []
    if score < 5:
        findings.append(
            Finding(
                check="scorecard",
                severity="high",
                title=f"OpenSSF Scorecard is low: {score:.1f}/10",
                detail="Review the failing checks on scorecard.dev.",
                url=f"https://scorecard.dev/viewer/?uri=github.com/{repo}",
                key="scorecard:score",
            )
        )
    elif score < 7:
        findings.append(
            Finding(
                check="scorecard",
                severity="medium",
                title=f"OpenSSF Scorecard below target: {score:.1f}/10",
                detail="Target is 7.0 or higher.",
                url=f"https://scorecard.dev/viewer/?uri=github.com/{repo}",
                key="scorecard:score",
            )
        )
    return _status_for(findings), findings, [], score


def collect(
    repo: str,
    github: GitHub,
    expected_checks: set[str] | None = None,
    ruleset_name: str | None = None,
    include_scorecard: bool = True,
    now: float | None = None,
    expected_ruleset: dict | None = None,
    config_errors: list[tuple[str, str]] | None = None,
) -> Report:
    """config_errors: (key, message) pairs for inputs that could not be read.

    An unreadable input must become a finding: silently dropping the check it
    feeds is exactly the blind spot this audit exists to close.
    """
    timestamp = datetime.fromtimestamp(now if now is not None else time.time(), UTC)
    report = Report(repo=repo, generated_at=timestamp.isoformat(timespec="seconds"))

    status, repo_data = github.get(f"/repos/{repo}")
    if status != 200 or not isinstance(repo_data, dict):
        report.checks["api"] = "fail"
        report.findings.append(
            Finding(
                check="api",
                severity="high",
                title=f"Cannot read repository {repo} (HTTP {status})",
                detail="Posture could not be evaluated.",
                url=f"https://github.com/{repo}",
                key="api:read",
            )
        )
        return report

    checks = (
        ("security_settings", lambda: check_security_settings(repo, repo_data)),
        ("secret_scanning", lambda: check_secret_scanning(github, repo)),
        ("dependabot", lambda: check_dependabot(github, repo)),
        ("code_scanning", lambda: check_code_scanning(github, repo)),
        (
            "ruleset",
            lambda: check_ruleset(
                github, repo, expected_checks, ruleset_name, expected_ruleset
            ),
        ),
        ("actions", lambda: check_actions_policy(github, repo)),
    )
    for name, run in checks:
        state, findings, notes = run()
        report.checks[name] = state
        report.findings.extend(findings)
        report.notes.extend(notes)
        # A check whose data source failed must not have its previous findings
        # treated as resolved below.
        if state == "skipped" or any(
            "unreadable" in note or "unavailable" in note for note in notes
        ):
            report.unavailable.add(name)

    if include_scorecard:
        state, findings, notes, score = check_scorecard(github, repo)
        report.checks["scorecard"] = state
        report.findings.extend(findings)
        report.notes.extend(notes)
        report.scorecard = score
        if state == "skipped":
            report.unavailable.add("scorecard")

    for key, message in config_errors or []:
        report.findings.append(
            Finding(
                check="config",
                severity="medium",
                title="Posture input could not be read",
                detail=message,
                url=f"https://github.com/{repo}/actions",
                key=key,
            )
        )
        if report.checks.get("config") is None:
            report.checks["config"] = "warn"

    if any(key.startswith("config:") for key, _ in config_errors or []):
        # The ruleset comparison depends on ci.yml and the committed ruleset
        # file; without them the check cannot be trusted.
        report.unavailable.add("ruleset")

    report.notes = list(dict.fromkeys(report.notes))
    return report


def expected_checks_from_ci(path: str) -> set[str]:
    """Parse job names from a ci.yml, minus push-only jobs."""
    import yaml

    with open(path, encoding="utf-8") as fh:
        try:
            workflow = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            raise ValueError(f"invalid YAML: {exc}") from exc
    if not isinstance(workflow, dict):
        raise TypeError("workflow is not a mapping")
    jobs = workflow.get("jobs") or {}
    if not isinstance(jobs, dict):
        raise TypeError("jobs is not a mapping")
    names = {
        str(job.get("name", job_id))
        for job_id, job in jobs.items()
        if isinstance(job, dict)
    }
    # Keep in sync with scripts/check_required_checks.py.
    return names - {"Deploy Check"}


def render_markdown(report: Report) -> str:
    counts = report.counts
    lines = [f"## 🩺 GitHub Posture — `{report.repo}`", ""]
    if report.total:
        parts = [
            f"{SEVERITY_ICON[sev]} {counts[sev]} {sev}"
            for sev in SEVERITY_RANK
            if counts.get(sev)
        ]
        lines.append(f"**{report.total} finding(s):** " + " · ".join(parts))
    else:
        lines.append("**No findings.** ✅")
    lines.append("")
    lines.append("| Check | Status |")
    lines.append("|---|---|")
    for name, state in report.checks.items():
        lines.append(f"| `{name}` | {STATUS_ICON.get(state, state)} {state} |")

    if report.total:
        lines += ["", "### Findings", ""]
        for finding in report.sorted_findings():
            title = f"[{finding.title}]({finding.url})" if finding.url else finding.title
            lines.append(f"- {SEVERITY_ICON[finding.severity]} **{finding.severity}** — {title}")
            if finding.detail:
                lines.append(f"  - {finding.detail}")

    if report.scorecard is not None:
        lines += ["", f"**OpenSSF Scorecard:** {report.scorecard:.1f}/10"]

    if report.notes:
        lines += ["", "> " + "\n> ".join(report.notes)]

    lines += ["", f"_Generated {report.generated_at}_", ""]
    return "\n".join(lines)


def render_json(report: Report) -> str:
    payload = {
        "repo": report.repo,
        "generated_at": report.generated_at,
        "scorecard": report.scorecard,
        "checks": report.checks,
        "counts": report.counts,
        "total": report.total,
        "findings": [
            {**f.__dict__, "id": f.fingerprint} for f in report.sorted_findings()
        ],
        "notes": report.notes,
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def load_baseline(path: str) -> dict[str, str]:
    """Read a previous JSON report into {fingerprint: title}."""
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    baseline: dict[str, str] = {}
    for finding in payload.get("findings") or []:
        fingerprint = finding.get("id")
        if fingerprint:
            baseline[str(fingerprint)] = str(finding.get("title") or "")
    return baseline


def new_and_resolved(
    report: Report, baseline: dict[str, str]
) -> tuple[list[Finding], list[str]]:
    current = {f.fingerprint for f in report.findings}
    new = [f for f in report.sorted_findings() if f.fingerprint not in baseline]
    resolved = [
        title
        for fid, title in baseline.items()
        if fid not in current and fid.split(":", 1)[0] not in report.unavailable
    ]
    return new, resolved


def render_prometheus(report: Report) -> str:
    stamp = 0
    try:
        stamp = int(datetime.fromisoformat(report.generated_at).timestamp())
    except ValueError:
        pass

    lines = [
        "# HELP github_posture_findings Open findings by severity.",
        "# TYPE github_posture_findings gauge",
    ]
    for sev, count in report.counts.items():
        lines.append(f'github_posture_findings{{severity="{sev}"}} {count}')

    lines += [
        "# HELP github_posture_check_ok 1 when the check passed, 0 otherwise.",
        "# TYPE github_posture_check_ok gauge",
    ]
    for name, state in sorted(report.checks.items()):
        lines.append(f'github_posture_check_ok{{check="{name}"}} {1 if state == "ok" else 0}')

    lines += [
        "# HELP github_posture_check_findings Findings per check.",
        "# TYPE github_posture_check_findings gauge",
    ]
    per_check = {name: 0 for name in report.checks}
    for finding in report.findings:
        per_check[finding.check] = per_check.get(finding.check, 0) + 1
    for name, count in sorted(per_check.items()):
        lines.append(f'github_posture_check_findings{{check="{name}"}} {count}')

    if report.scorecard is not None:
        lines.append(f"github_posture_scorecard_score {report.scorecard:g}")
    lines.append(f"github_posture_last_run_timestamp {stamp}")
    return "\n".join(lines) + "\n"


def render_telegram(
    report: Report,
    new: list[Finding] | None = None,
    resolved: list[str] | None = None,
) -> str:
    """Digest for Telegram. Empty string means "nothing worth sending"."""
    new = report.sorted_findings() if new is None else new
    resolved = resolved or []
    if not new and not resolved:
        return ""

    esc = html.escape
    lines = [f"🩺 <b>GitHub Posture</b> — {esc(report.repo)}"]

    if new:
        counts = {sev: 0 for sev in SEVERITY_RANK}
        for finding in new:
            counts[finding.severity] = counts.get(finding.severity, 0) + 1
        parts = [
            f"{SEVERITY_ICON[sev]} {counts[sev]}" for sev in SEVERITY_RANK if counts.get(sev)
        ]
        noun = "finding" if len(new) == 1 else "findings"
        headline = f"⚠️ <b>{len(new)} new {noun}</b> · " + " · ".join(parts)
        if resolved:
            headline += f" · ✅ {len(resolved)} resolved"
        lines += [headline, ""]
        for finding in new[:6]:
            lines.append(f"{SEVERITY_ICON[finding.severity]} {esc(finding.title)}")
        if len(new) > 6:
            lines.append(f"… and {len(new) - 6} more")
        if resolved:
            lines.append("")
    else:
        lines += [f"✅ <b>All clear</b> · {len(resolved)} resolved", ""]

    if resolved:
        lines.append(f"✅ <b>Resolved</b> ({len(resolved)})")
        for title in resolved[:3]:
            # Strikethrough makes it unambiguous that the state is in the past.
            lines.append(f"• <s>{esc(title)}</s>")
        if len(resolved) > 3:
            lines.append(f"… and {len(resolved) - 3} more")
        lines.append("")

    if lines[-1] != "":
        lines.append("")
    green = sum(1 for state in report.checks.values() if state == "ok")
    footer = f"{green}/{len(report.checks)} checks green"
    if report.scorecard is not None:
        footer += f" · Scorecard {report.scorecard:.1f}/10"
    lines.append(footer)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument(
        "--token",
        default=(
            os.environ.get("POSTURE_TOKEN")
            or os.environ.get("GH_TOKEN")
            or os.environ.get("GITHUB_TOKEN")
        ),
    )
    parser.add_argument("--ci-workflow", help="parse required jobs from this ci.yml")
    parser.add_argument("--expected-checks", help="comma-separated required check names")
    parser.add_argument("--ruleset", help="prefer this ruleset name")
    parser.add_argument(
        "--ruleset-file",
        help=f"committed ruleset to diff against (default: {RULESET_FILE} if present)",
    )
    parser.add_argument("--no-scorecard", action="store_true")
    parser.add_argument(
        "--format",
        choices=["markdown", "json", "prometheus", "telegram"],
        default="markdown",
    )
    parser.add_argument("--write-dir", help="write all renderings into this directory")
    parser.add_argument(
        "--baseline",
        help="previous JSON report; only new/resolved findings are sent to Telegram",
    )
    parser.add_argument(
        "--telegram-on", choices=["findings", "always", "never"], default="findings"
    )
    parser.add_argument(
        "--fail-on",
        choices=["none", "critical", "high", "medium", "low", "any"],
        default="none",
    )
    args = parser.parse_args(argv)

    if not args.repo:
        parser.error("--repo is required (or set GITHUB_REPOSITORY)")

    config_errors: list[tuple[str, str]] = []
    expected: set[str] | None = None
    if args.expected_checks:
        expected = {c.strip() for c in args.expected_checks.split(",") if c.strip()}
    else:
        ci_path = args.ci_workflow or CI_WORKFLOW
        try:
            expected = expected_checks_from_ci(ci_path)
        except (OSError, ImportError, KeyError, TypeError, ValueError) as exc:
            config_errors.append(("config:ci-workflow", f"{ci_path}: {exc}"))

    expected_ruleset: dict | None = None
    ruleset_path = args.ruleset_file or (RULESET_FILE if Path(RULESET_FILE).is_file() else None)
    if ruleset_path:
        try:
            expected_ruleset = load_expected_ruleset(ruleset_path)
        except (OSError, ValueError, TypeError) as exc:
            config_errors.append(("config:ruleset-file", f"{ruleset_path}: {exc}"))

    report = collect(
        args.repo,
        GitHub(
            args.token,
            fallback=os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"),
        ),
        expected_checks=expected,
        ruleset_name=args.ruleset,
        include_scorecard=not args.no_scorecard,
        expected_ruleset=expected_ruleset,
        config_errors=config_errors,
    )

    baseline = load_baseline(args.baseline) if args.baseline else {}
    if args.telegram_on == "never":
        new_findings: list[Finding] = []
        resolved: list[str] = []
    elif args.telegram_on == "always" or not baseline:
        new_findings, resolved = report.sorted_findings(), []
    else:
        new_findings, resolved = new_and_resolved(report, baseline)

    def telegram_message() -> str:
        return render_telegram(report, new=new_findings, resolved=resolved)

    renderers = {
        "markdown": render_markdown,
        "json": render_json,
        "prometheus": render_prometheus,
    }
    print(renderers[args.format](report) if args.format in renderers else telegram_message())

    if args.write_dir:
        out = Path(args.write_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "github-posture.md").write_text(render_markdown(report), encoding="utf-8")
        (out / "github-posture.json").write_text(render_json(report), encoding="utf-8")
        (out / "github-posture.prom").write_text(
            render_prometheus(report), encoding="utf-8"
        )
        if telegram_message():
            (out / "github-posture.telegram.html").write_text(
                telegram_message(), encoding="utf-8"
            )

    # Exit 3 = threshold breached (the workflow turns it into a failure after
    # notifying). Exit 1 is reserved for real crashes, so the two never mix.
    if args.fail_on != "none":
        limit = 4 if args.fail_on == "any" else SEVERITY_RANK[args.fail_on]
        if any(SEVERITY_RANK[f.severity] <= limit for f in report.findings):
            return EXIT_THRESHOLD
    return 0


if __name__ == "__main__":
    sys.exit(main())
