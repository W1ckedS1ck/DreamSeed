"""Fixture-driven tests for scripts/github_posture.py.

No network: a fake client returns canned API responses, so the assertions
cover parsing, severity mapping and rendering — not GitHub's availability.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import github_posture as gp

REPO = "acme/demo"
SCORECARD_URL = gp.SCORECARD_API.format(repo=REPO)
FAKE_TOKEN = "test-token"


class FakeGitHub:
    def __init__(self, routes: dict, public: dict | None = None) -> None:
        self.routes = routes
        self.public = public or {}
        self.calls: list[str] = []

    def get(self, path: str) -> tuple[int, object | None]:
        self.calls.append(path)
        return self.routes.get(path, (404, None))

    def get_public(self, url: str) -> tuple[int, object | None]:
        self.calls.append(url)
        return self.public.get(url, (404, None))


def healthy_routes() -> dict:
    return {
        f"/repos/{REPO}": (
            200,
            {
                "security_and_analysis": {
                    "secret_scanning": {"status": "enabled"},
                    "secret_scanning_push_protection": {"status": "enabled"},
                    "dependabot_security_updates": {"status": "enabled"},
                    "secret_scanning_validity_checks": {"status": "disabled"},
                    "secret_scanning_non_provider_patterns": {"status": "disabled"},
                }
            },
        ),
        f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100": (200, []),
        f"/repos/{REPO}/dependabot/alerts?state=open&per_page=100": (200, []),
        f"/repos/{REPO}/code-scanning/alerts?state=open&per_page=100": (200, []),
        f"/repos/{REPO}/rulesets": (
            200,
            [
                {
                    "id": 1,
                    "name": "Protect Main",
                    "target": "branch",
                    "enforcement": "active",
                }
            ],
        ),
        f"/repos/{REPO}/rulesets/1": (
            200,
            {
                "name": "Protect Main",
                "enforcement": "active",
                "bypass_actors": [],
                "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"]}},
                "rules": [
                    {"type": "deletion"},
                    {"type": "non_fast_forward"},
                    {"type": "pull_request"},
                    {
                        "type": "required_status_checks",
                        "parameters": {
                            "required_status_checks": [
                                {"context": "lint"},
                                {"context": "test"},
                            ]
                        },
                    },
                ],
            },
        ),
        f"/repos/{REPO}/actions/permissions/workflow": (
            200,
            {
                "default_workflow_permissions": "read",
                "can_approve_pull_request_reviews": False,
            },
        ),
        f"/repos/{REPO}/actions/permissions": (
            200,
            {
                "enabled": True,
                "allowed_actions": "all",
                "sha_pinning_required": True,
            },
        ),
    }


def build(routes: dict, expected: set[str] | None = None, scorecard: float | None = 8.4):
    public = {SCORECARD_URL: (200, {"score": scorecard})} if scorecard is not None else {}
    client = FakeGitHub(routes, public)
    return gp.collect(
        REPO,
        client,  # type: ignore[arg-type]
        expected_checks=expected,
        include_scorecard=scorecard is not None,
        now=1_700_000_000,
    )


def test_clean_repo_has_no_findings() -> None:
    report = build(healthy_routes(), expected={"lint", "test"})
    assert report.total == 0
    assert report.checks["ruleset"] == "ok"
    assert report.scorecard == 8.4
    # Paid Secret Protection features must be notes, not findings.
    assert any("Secret Protection" in note for note in report.notes)


def test_secret_alert_is_critical_and_never_leaks_the_value() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200,
        [
            {
                "secret_type_display_name": "GitHub Personal Access Token",
                "secret": "TEST_ONLY_NOT_A_REAL_CREDENTIAL",
                "html_url": "https://github.com/acme/demo/security/secret-scanning/1",
            }
        ],
    )
    report = build(routes)

    assert report.total == 1
    finding = report.findings[0]
    assert finding.severity == "critical"
    assert "GitHub Personal Access Token" in finding.title
    assert "TEST_ONLY_NOT_A_REAL_CREDENTIAL" not in gp.render_markdown(report)
    assert "TEST_ONLY_NOT_A_REAL_CREDENTIAL" not in gp.render_json(report)
    assert "TEST_ONLY_NOT_A_REAL_CREDENTIAL" not in gp.render_telegram(report)


def test_ruleset_missing_required_check_is_high() -> None:
    report = build(healthy_routes(), expected={"lint", "test", "gitleaks"})
    finding = next(f for f in report.findings if f.check == "ruleset")
    assert finding.severity == "high"
    assert "gitleaks" in finding.detail
    assert report.checks["ruleset"] == "fail"


def test_ruleset_bypass_and_missing_rules_are_flagged() -> None:
    routes = healthy_routes()
    detail = routes[f"/repos/{REPO}/rulesets/1"][1]
    detail["bypass_actors"] = [{"actor_type": "RepositoryRole", "actor_id": 5}]
    detail["rules"] = [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "lint"}, {"context": "test"}]}}]

    report = build(routes, expected={"lint", "test"})
    titles = " ".join(f.title for f in report.findings)
    assert "bypass actor" in titles
    assert "branch deletion" in titles
    assert "force pushes" in titles
    assert "pull requests" in titles


def test_disabled_security_switches_are_flagged() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}"][1]["security_and_analysis"] = {
        "secret_scanning": {"status": "disabled"},
        "secret_scanning_push_protection": {"status": "disabled"},
        "dependabot_security_updates": {"status": "disabled"},
    }
    report = build(routes)
    severities = {f.severity for f in report.findings if f.check == "security_settings"}
    assert severities == {"high", "medium"}


def test_dependabot_alerts_grouped_by_severity() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/dependabot/alerts?state=open&per_page=100"] = (
        200,
        [
            {
                "security_advisory": {"severity": "high"},
                "dependency": {"package": {"name": "lodash"}},
            },
            {
                "security_advisory": {"severity": "high"},
                "dependency": {"package": {"name": "express"}},
            },
            {
                "security_advisory": {"severity": "moderate"},
                "dependency": {"package": {"name": "qs"}},
            },
        ],
    )
    report = build(routes)
    titles = sorted(f.title for f in report.findings if f.check == "dependabot")
    assert titles == [
        "Dependabot: 1 open medium-severity alert(s)",
        "Dependabot: 2 open high-severity alert(s)",
    ]
    high = next(f for f in report.findings if "2 open high" in f.title)
    assert "express" in high.detail and "lodash" in high.detail


def test_code_scanning_error_maps_to_high() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/code-scanning/alerts?state=open&per_page=100"] = (
        200,
        [{"rule": {"id": "py/unsafe-html", "severity": "error"}}],
    )
    report = build(routes)
    finding = next(f for f in report.findings if f.check == "code_scanning")
    assert finding.severity == "high"
    assert "py/unsafe-html" in finding.detail


def test_unreadable_api_returns_single_high_finding() -> None:
    report = build({})
    assert report.total == 1
    assert report.findings[0].check == "api"
    assert report.findings[0].severity == "high"
    assert report.checks == {"api": "fail"}


def test_prometheus_output_exposes_findings_and_checks() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200,
        [{"secret_type_display_name": "Stripe API key"}],
    )
    text = gp.render_prometheus(build(routes))
    assert 'github_posture_findings{severity="critical"} 1' in text
    assert 'github_posture_check_ok{check="ruleset"} 1' in text
    assert 'github_posture_check_findings{check="secret_scanning"} 1' in text
    assert "github_posture_scorecard_score 8.4" in text


def test_telegram_escapes_html() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200,
        [{"secret_type_display_name": "<script>alert(1)</script>"}],
    )
    message = gp.render_telegram(build(routes), "https://example.test/run?a=1&b=2")
    assert "<script>" not in message
    assert "&lt;script&gt;" in message
    assert "a=1&amp;b=2" in message


def test_expected_checks_from_ci_excludes_push_only_jobs() -> None:
    checks = gp.expected_checks_from_ci(".github/workflows/ci.yml")
    assert ".env Parser Contract" in checks
    assert "Deploy Check" not in checks


def test_json_findings_carry_stable_ids() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200,
        [{"secret_type_display_name": "Stripe API key"}],
    )
    payload = json.loads(gp.render_json(build(routes)))
    assert payload["findings"][0]["id"] == "secret_scanning:secret:Stripe API key:critical"


def test_baseline_diff_reports_only_changes(tmp_path: Path) -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200,
        [{"secret_type_display_name": "Stripe API key"}],
    )
    report = build(routes)
    baseline_file = tmp_path / "previous.json"
    baseline_file.write_text(gp.render_json(report), encoding="utf-8")
    baseline = gp.load_baseline(str(baseline_file))

    # Same finding, only the count changed: nothing new to report.
    routes_updated = healthy_routes()
    routes_updated[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200,
        [
            {"secret_type_display_name": "Stripe API key"},
            {"secret_type_display_name": "Stripe API key"},
        ],
    )
    updated = build(routes_updated)
    new, resolved = gp.new_and_resolved(updated, baseline)
    assert new == []
    assert resolved == []

    # After remediation the previous finding is reported as resolved.
    fixed = build(healthy_routes())
    new, resolved = gp.new_and_resolved(fixed, baseline)
    assert new == []
    assert resolved == ["Secret scanning: 1 open Stripe API key alert(s)"]
    assert "Resolved: 1" in gp.render_telegram(fixed, new=[], resolved=resolved)


def test_clean_run_sends_nothing_to_telegram() -> None:
    report = build(healthy_routes())
    assert gp.render_telegram(report, new=[], resolved=[]) == ""


def test_public_fetch_drops_github_headers(monkeypatch) -> None:
    """Scorecard answers 406 to the GitHub media type; public calls must not send it."""
    captured: dict[str, str] = {}

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_args) -> bool:
            return False

        def read(self) -> bytes:
            return b'{"score": 8.0}'

    def fake_urlopen(req, **_kwargs):
        captured.update({k.lower(): v for k, v in req.headers.items()})
        return FakeResponse()

    monkeypatch.setattr(gp.urllib.request, "urlopen", fake_urlopen)
    status, data = gp.GitHub(token=FAKE_TOKEN).get_public(SCORECARD_URL)

    assert status == 200
    assert data == {"score": 8.0}
    assert captured["accept"] == "application/json"
    assert "authorization" not in captured
    assert "x-github-api-version" not in captured


def test_token_scope_403_is_reported_not_hidden() -> None:
    routes = healthy_routes()
    denied = (403, {"message": "Resource not accessible by integration"})
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = denied
    routes[f"/repos/{REPO}/dependabot/alerts?state=open&per_page=100"] = denied

    report = build(routes)
    titles = " ".join(f.title for f in report.findings)
    assert "Secret scanning alerts are unreadable" in titles
    assert "Dependabot alerts are unreadable" in titles
    assert report.checks["secret_scanning"] == "warn"
    assert report.checks["dependabot"] == "warn"


def test_missing_security_analysis_is_not_a_false_positive() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}"][1].pop("security_and_analysis", None)
    report = build(routes)
    assert not [f for f in report.findings if f.check == "security_settings"]
    assert report.checks["security_settings"] == "skipped"


def test_unreadable_actions_policy_is_skipped_not_ok() -> None:
    routes = healthy_routes()
    routes.pop(f"/repos/{REPO}/actions/permissions/workflow")
    routes.pop(f"/repos/{REPO}/actions/permissions")
    report = build(routes)
    assert report.checks["actions"] == "skipped"
    assert not [f for f in report.findings if f.check == "actions"]


def _ruleset_detail(routes: dict) -> dict:
    return routes[f"/repos/{REPO}/rulesets/1"][1]


def test_rulesets_403_is_medium_not_a_missing_protection() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/rulesets"] = (403, {"message": "Resource not accessible"})
    report = build(routes)
    ruleset = [f for f in report.findings if f.check == "ruleset"]
    assert [f.severity for f in ruleset] == ["medium"]
    assert ruleset[0].key == "ruleset:unreadable"
    assert report.checks["ruleset"] == "warn"


def test_network_error_on_ruleset_is_not_critical() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/rulesets"] = (0, None)
    report = build(routes)
    assert "critical" not in {f.severity for f in report.findings}


def test_unreadable_ruleset_detail_is_not_reported_as_missing() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/rulesets/1"] = (403, None)
    report = build(routes)
    keys = {f.key for f in report.findings if f.check == "ruleset"}
    assert keys == {"ruleset:unreadable"}


def test_ruleset_404_is_still_critical() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/rulesets"] = (200, [])
    report = build(routes)
    finding = next(f for f in report.findings if f.check == "ruleset")
    assert finding.severity == "critical"
    assert finding.key == "ruleset:missing"


def test_ruleset_drift_is_flagged_and_matching_policy_is_clean() -> None:
    expected = gp.ruleset_snapshot(_ruleset_detail(healthy_routes()))
    report = gp.collect(REPO, FakeGitHub(healthy_routes()), expected_checks={"lint", "test"},
                        include_scorecard=False, expected_ruleset=expected)
    assert report.total == 0

    routes = healthy_routes()
    _ruleset_detail(routes)["bypass_actors"] = [{"actor_type": "Team", "actor_id": 9}]
    drifted = gp.collect(REPO, FakeGitHub(routes), expected_checks={"lint", "test"},
                         include_scorecard=False, expected_ruleset=expected)
    drift = [f for f in drifted.findings if f.key == "ruleset:drift"]
    assert len(drift) == 1
    assert drift[0].severity == "high"
    assert "bypass_actors" in drift[0].detail


def test_committed_ruleset_matches_ci_required_checks() -> None:
    root = Path(__file__).resolve().parents[2]
    committed = gp.load_expected_ruleset(str(root / gp.RULESET_FILE))
    contexts = {
        c["context"]
        for rule in committed["rules"]
        if rule["type"] == "required_status_checks"
        for c in rule["parameters"]["required_status_checks"]
    }
    assert contexts == gp.expected_checks_from_ci(str(root / gp.CI_WORKFLOW))


def test_null_dependabot_package_does_not_crash_the_audit() -> None:
    routes = healthy_routes()
    routes[f"/repos/{REPO}/dependabot/alerts?state=open&per_page=100"] = (
        200,
        [{"security_advisory": {"severity": "high"}, "dependency": {"package": None}}],
    )
    report = build(routes)
    assert [f.severity for f in report.findings if f.check == "dependabot"] == ["high"]


def test_unreadable_config_input_becomes_a_finding() -> None:
    report = gp.collect(
        REPO,
        FakeGitHub(healthy_routes()),
        include_scorecard=False,
        config_errors=[("config:ci-workflow", "missing.yml: No such file")],
    )
    finding = next(f for f in report.findings if f.check == "config")
    assert finding.severity == "medium"
    assert report.checks["config"] == "warn"


def _exit_code(routes: dict, capsys, *extra: str, monkeypatch, ruleset_file: Path) -> int:
    monkeypatch.setattr(gp, "GitHub", lambda token=None: FakeGitHub(routes))
    code = gp.main([
        "--repo", REPO, "--no-scorecard", "--format", "json",
        "--expected-checks", "lint,test", "--ruleset-file", str(ruleset_file), *extra,
    ])
    capsys.readouterr()
    return code


def test_fail_on_returns_threshold_code_and_crash_is_not_confused(
    tmp_path: Path, monkeypatch, capsys
) -> None:
    ruleset_file = tmp_path / "rs.json"
    ruleset_file.write_text(
        json.dumps(gp.ruleset_snapshot(_ruleset_detail(healthy_routes()))), encoding="utf-8"
    )
    clean = _exit_code(healthy_routes(), capsys, "--fail-on", "high",
                       monkeypatch=monkeypatch, ruleset_file=ruleset_file)
    assert clean == 0

    routes = healthy_routes()
    routes[f"/repos/{REPO}/secret-scanning/alerts?state=open&per_page=100"] = (
        200, [{"secret_type_display_name": "Stripe API key"}])
    breached = _exit_code(routes, capsys, "--fail-on", "high",
                          monkeypatch=monkeypatch, ruleset_file=ruleset_file)
    assert breached == gp.EXIT_THRESHOLD == 3

    no_gate = _exit_code(routes, capsys, monkeypatch=monkeypatch, ruleset_file=ruleset_file)
    assert no_gate == 0
