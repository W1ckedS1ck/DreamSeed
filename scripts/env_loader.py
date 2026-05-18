"""Shared .env loader for DreamSeed Python scripts."""

import os
import sys


def load_env(env_path: str = "") -> None:
    """Parse KEY=VALUE from a .env file, exporting to os.environ.

    Skips empty lines and comments. Values are stripped of
    surrounding single or double quotes.
    """
    if not env_path:
        env_path = os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.isfile(env_path):
        print(f"[ERROR] .env not found: {env_path}", file=sys.stderr)
        sys.exit(1)
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            value = value.strip().strip('"').strip("'")
            os.environ.setdefault(key.strip(), value)
