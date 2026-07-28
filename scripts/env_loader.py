"""Shared .env loader for DreamSeed Python scripts."""

import os
import re

BLOCKED_VARS = re.compile(
    r'^(PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|SHELL|SHELLOPTS|BASHOPTS|BASH_FUNC_.*)$'
)


def load_env(env_path: str = "") -> None:
    """Parse KEY=VALUE from a .env file, exporting to os.environ.

    Skips empty lines, comments, and blocked security-sensitive vars.
    Values are stripped of surrounding single or double quotes.
    """
    if not env_path:
        env_path = os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.isfile(env_path):
        raise FileNotFoundError(f".env not found: {env_path}")
    try:
        f = open(env_path)
    except PermissionError:
        raise PermissionError(f"Permission denied: {env_path}") from None
    with f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[7:]
            key, _, value = line.partition("=")
            key = key.strip()
            if BLOCKED_VARS.match(key):
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            if '$(' in value or '`' in value:
                raise ValueError(f"Shell injection pattern detected in {key}")
            os.environ[key] = value
