"""Duplicated version pins must not drift."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def test_uv_version_matches_between_ci_and_ansible() -> None:
    ci = yaml.safe_load(
        (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    )
    group = yaml.safe_load(
        (ROOT / "ansible/group_vars/all.yml").read_text(encoding="utf-8")
    )

    ci_version = ci["env"]["UV_VERSION"]
    match = re.search(r"default\('([^']+)'", group["uv_version"])
    assert match, f"cannot parse uv_version: {group['uv_version']}"
    assert ci_version == match.group(1)
