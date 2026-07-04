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
    try:
        f = open(env_path)
    except PermissionError:
        print(f"[ERROR] Permission denied: {env_path}", file=sys.stderr)
        sys.exit(1)
    with f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[7:]
            key, _, value = line.partition("=")
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            os.environ[key.strip()] = value
