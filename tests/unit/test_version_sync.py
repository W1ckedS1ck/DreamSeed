"""Duplicated version pins must not drift."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def test_uv_version_matches_between_ci_and_ansible() -> None:
    ci = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
    group = yaml.safe_load(
        (ROOT / "ansible/group_vars/all.yml").read_text(encoding="utf-8")
    )

    ci_version = ci["env"]["UV_VERSION"]
    match = re.search(r"default\('([^']+)'", group["uv_version"])
    assert match, f"cannot parse uv_version: {group['uv_version']}"
    assert ci_version == match.group(1)


def test_uv_version_matches_setup_ansible_action() -> None:
    """The composite action installs uv with its own pin — keep it in sync."""
    ci = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
    action = yaml.safe_load(
        (ROOT / ".github/actions/setup-ansible/action.yml").read_text(encoding="utf-8")
    )

    assert action["inputs"]["uv-version"]["default"] == ci["env"]["UV_VERSION"]


def test_uv_version_matches_github_posture() -> None:
    ci = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
    posture = yaml.safe_load(
        (ROOT / ".github/workflows/github-posture.yml").read_text(encoding="utf-8")
    )

    assert posture["env"]["UV_VERSION"] == ci["env"]["UV_VERSION"]


def _lock_python_version(path: Path) -> str:
    header = "\n".join(path.read_text(encoding="utf-8").splitlines()[:3])
    match = re.search(r"--python-version=([0-9.]+)", header)
    assert match, f"no --python-version in {path.name} header"
    return match.group(1)


def _setup_python_versions(container: dict) -> set[str]:
    return {
        step["with"]["python-version"]
        for step in container["steps"]
        if str(step.get("uses", "")).startswith("actions/setup-python")
    }


def test_ci_python_version_matches_lock_and_workflow() -> None:
    lock = _lock_python_version(ROOT / "ci/requirements.txt")
    ci = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
    versions = {
        version
        for job in ci["jobs"].values()
        for version in _setup_python_versions(job)
    }

    assert versions == {lock}, (
        f"ci.yml setup-python versions {versions} != lock target {lock}"
    )


def test_ansible_python_version_matches_lock_and_action() -> None:
    lock = _lock_python_version(ROOT / "ansible/requirements-deploy.txt")
    action = yaml.safe_load(
        (ROOT / ".github/actions/setup-ansible/action.yml").read_text(encoding="utf-8")
    )

    assert _setup_python_versions(action["runs"]) == {lock}
