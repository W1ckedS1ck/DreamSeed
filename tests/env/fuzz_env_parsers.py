"""Differential fuzz of the three .env parsers.

Generates well-formed .env files from the subset of the contract that the
fixtures in tests/env/ already pin (plain / quoted / export / inline-comment /
empty / multi-line / HOME + prior-key expansion), then asserts all three
parsers return rc=0 with identical KEY=value output:

  - lib/env.sh           parse_env_file
  - scripts/common_functions.sh   load_env
  - scripts/env_loader.py         load_env

Deterministic (fixed seed), so any failure is reproducible. A divergence here
is a real contract bug, not a documented intentional difference (those are
covered by scripts/check_env_contract.sh fixtures).
"""

from __future__ import annotations

import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HARNESS = os.path.join(ROOT, "scripts", "check_env_contract.sh")
SEED = 20261018
CASES = 80

KEYS = [f"EC_FZ_{i:02d}" for i in range(1, 13)]
PLAIN = "abcdefghijklmnopqrstuvwxyz0123456789._/-"
COMMENT = "abcXYZ 0123"


def _token(rng: random.Random, alphabet: str, lo: int = 1, hi: int = 8) -> str:
    return "".join(rng.choice(alphabet) for _ in range(rng.randint(lo, hi)))


def _comment(rng: random.Random) -> str:
    return "# " + _token(rng, COMMENT, 1, 12)


def _value(rng: random.Random, refable: list[str]) -> tuple[str, bool]:
    """Return (value_text, is_plain_value). plain values are safe to reference
    from later expansion cases without chained-expansion ambiguity."""
    kind = rng.randrange(8)
    if kind == 0:
        return _token(rng, PLAIN), True
    if kind == 1:
        return f"{_token(rng, PLAIN)} {_comment(rng)}", True
    if kind == 2:
        return f'"{_token(rng, PLAIN + " ", 1, 12)}"', True
    if kind == 3:
        ref = rng.choice(refable)
        expr = f"${{{ref}}}" if rng.random() < 0.5 else f"${ref}"
        return f'"{expr}/{_token(rng, PLAIN)}"', False
    if kind == 4:
        # Single-quoted: $ and # are literal.
        return f"'{_token(rng, PLAIN + ' $#', 1, 12)}'", True
    if kind == 5:
        return f'"{_token(rng, PLAIN)}\n{_token(rng, PLAIN + " ", 1, 10)}"', False
    if kind == 6:
        return f"'{_token(rng, PLAIN)}\n{_token(rng, PLAIN)}' {_comment(rng)}", False
    return "", True


def _case(rng: random.Random) -> str:
    lines: list[str] = []
    refable = ["HOME"]
    for key in KEYS:
        roll = rng.random()
        if roll < 0.12:
            lines.append("")
            continue
        if roll < 0.22:
            lines.append(_comment(rng))
            continue
        value, is_plain = _value(rng, refable)
        prefix = "export " if rng.random() < 0.3 else ""
        lines.append(f"{prefix}{key}={value}")
        if is_plain:
            refable.append(key)
    return "\n".join(lines) + "\n"


def _run(parser: str, path: str, keys: str) -> subprocess.CompletedProcess[str]:
    cmd = f'source "{HARNESS}"\nrun_one {parser} "{path}" "{keys}"'
    return subprocess.run(
        ["bash", "-c", cmd],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )


def main() -> int:
    rng = random.Random(SEED)
    keys = " ".join(KEYS)
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for n in range(CASES):
            content = _case(rng)
            path = os.path.join(tmp, f"case_{n:03d}.env")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
            results = {p: _run(p, path, keys) for p in ("lib", "server", "py")}
            rcs = {p: r.returncode for p, r in results.items()}
            outs = {p: r.stdout for p, r in results.items()}
            if not (
                set(rcs.values()) == {0}
                and outs["lib"] == outs["server"] == outs["py"]
            ):
                failures += 1
                print(f"FAIL case {n}: rc={rcs}", file=sys.stderr)
                print("--- input ---", file=sys.stderr)
                print(content, end="", file=sys.stderr)
                for p, r in results.items():
                    print(f"--- {p} (rc={r.returncode}) ---", file=sys.stderr)
                    print(r.stdout, end="", file=sys.stderr)
                if failures >= 3:
                    print("stopping after 3 failures", file=sys.stderr)
                    break

    if failures:
        print(f"{failures} divergent case(s)", file=sys.stderr)
        return 1
    print(f"OK: {CASES}/{CASES} random .env files parsed identically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
