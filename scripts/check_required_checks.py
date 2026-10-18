"""Assert that every PR-facing ci.yml job is a required check on Protect Main.

Root cause of the 2026-10-18 incident: the Protect Main ruleset required only 8
of the 12 ci.yml jobs, so Renovate's platformAutomerge merged a PR whose
"GitHub Actions Security" check was red. Required checks live in GitHub, not in
the repo, so this drift is otherwise invisible until a red check slips through.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

import yaml

RULESET_NAME = "Protect Main"
CI_WORKFLOW = ".github/workflows/ci.yml"
# Push-only jobs cannot be required status checks on pull requests.
PUSH_ONLY = {"Deploy Check"}
API = "https://api.github.com"


def _get(path: str, token: str | None) -> object:
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "required-checks-drift",
        },
    )
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def fetch_required_checks(repo: str, token: str | None) -> set[str]:
    rulesets = _get(f"/repos/{repo}/rulesets", token)
    ruleset = next((r for r in rulesets if r.get("name") == RULESET_NAME), None)
    if ruleset is None:
        raise RuntimeError(f"ruleset {RULESET_NAME!r} not found")
    if ruleset.get("enforcement") != "active":
        raise RuntimeError(f"ruleset {RULESET_NAME!r} is not active")
    detail = _get(f"/repos/{repo}/rulesets/{ruleset['id']}", token)
    for rule in detail.get("rules", []):
        if rule.get("type") == "required_status_checks":
            contexts = rule["parameters"]["required_status_checks"]
            return {c["context"] for c in contexts}
    raise RuntimeError(f"ruleset {RULESET_NAME!r} has no required_status_checks rule")


def ci_job_names() -> set[str]:
    with open(CI_WORKFLOW, encoding="utf-8") as fh:
        workflow = yaml.safe_load(fh)
    # GitHub falls back to the job id when a job has no explicit name.
    return {
        job.get("name", job_id) for job_id, job in workflow["jobs"].items()
    }


def main() -> int:
    repo = os.environ.get("GITHUB_REPOSITORY", "W1ckedS1ck/DreamSeed")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    expected = ci_job_names() - PUSH_ONLY

    try:
        required = fetch_required_checks(repo, token)
    except urllib.error.HTTPError as exc:
        # GITHUB_TOKEN may lack the Administration:read scope; the repo is
        # public, so retry unauthenticated.
        if exc.code not in (401, 403, 404):
            raise
        required = fetch_required_checks(repo, None)

    missing = sorted(expected - required)
    stale = sorted(required - expected)
    if missing or stale:
        print(f"Protect Main is out of sync with {CI_WORKFLOW}:", file=sys.stderr)
        for name in missing:
            print(f"  missing required check: {name}", file=sys.stderr)
        for name in stale:
            print(f"  stale required check (no such ci.yml job): {name}", file=sys.stderr)
        print(
            "Update Settings -> Rules -> Protect Main to match.",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: {len(expected)} PR-facing ci.yml jobs are all required on "
        f"{RULESET_NAME}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
