"""Guard rails for the uv-based Python install path.

pip is ~10x slower than uv on hash-pinned installs, and every workflow that
installs Python deps runs on the CI critical path. This test fails if a `pip
install` slips back into a workflow or composite action.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

WORKFLOWS = ROOT / ".github/workflows"
ACTIONS = ROOT / ".github/actions"

PIP_INSTALL = re.compile(r"(?<!uv )(?<![\w-])pip\s+install\b")


def _ci_files() -> list[Path]:
    files = sorted(WORKFLOWS.glob("*.yml"))
    files.extend(sorted(ACTIONS.glob("*/action.yml")))
    return files


def test_no_pip_install_in_ci() -> None:
    offenders = [
        str(path.relative_to(ROOT))
        for path in _ci_files()
        if PIP_INSTALL.search(path.read_text(encoding="utf-8"))
    ]
    assert not offenders, (
        "Use `uv pip install` instead of `pip install` in CI "
        f"(offenders: {', '.join(offenders)})"
    )


def test_requirements_installs_use_uv() -> None:
    for path in _ci_files():
        text = path.read_text(encoding="utf-8")
        if "-r ci/requirements.txt" not in text:
            continue
        assert "uv pip install --system --require-hashes -r ci/requirements.txt" in text, (
            f"{path.relative_to(ROOT)} must install ci/requirements.txt with uv"
        )
