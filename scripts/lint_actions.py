"""Shellcheck the inline `run:` blocks of composite actions.

actionlint checks workflow `run:` blocks, but not composite actions, and
ShellCheck itself only sees `*.sh` files. This script extracts each composite
action's `run:` script, prepends a bash shebang, and checks it.

Run from the repository root. Requires PyYAML and shellcheck.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACTIONS = ROOT / ".github" / "actions"


def main() -> int:
    try:
        import yaml
    except ImportError:
        print("skip: PyYAML not installed")
        return 0

    if shutil.which("shellcheck") is None:
        print("skip: shellcheck not installed")
        return 0

    checked = 0
    failures = 0
    for action in sorted(ACTIONS.glob("*/action.yml")):
        doc = yaml.safe_load(action.read_text(encoding="utf-8")) or {}
        steps = (doc.get("runs") or {}).get("steps") or []
        for index, step in enumerate(steps):
            script = step.get("run")
            if not isinstance(script, str):
                continue
            if "${{" in script:
                # GitHub expressions are not shell; skip instead of a known
                # false positive. actionlint does not cover composite actions.
                print(f"skip {action.name}:{index} (contains a GitHub expression)")
                continue

            with tempfile.NamedTemporaryFile(
                "w", suffix=".sh", delete=False, encoding="utf-8"
            ) as handle:
                handle.write("#!/usr/bin/env bash\n")
                handle.write(script)
                path = handle.name
            try:
                result = subprocess.run(
                    ["shellcheck", "--severity=warning", path],
                    text=True,
                    capture_output=True,
                    check=False,
                )
            finally:
                Path(path).unlink(missing_ok=True)

            checked += 1
            if result.returncode != 0:
                failures += 1
                print(
                    f"::error file={action}::{action.name} step {index} failed shellcheck"
                )
                print(result.stdout, result.stderr)

    print(f"composite actions: {checked} run block(s) checked, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
