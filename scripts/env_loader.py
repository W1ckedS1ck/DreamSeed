"""Shared .env loader for DreamSeed Python scripts.

Parsing contract mirrors the Bash parsers (lib/env.sh on the deploy side,
common_functions.sh load_env on the server side):
  - KEY=value, optional single/double quotes, inline comments;
  - multi-line quoted values (accumulated until the closing quote);
  - bounded $HOME/$UPPERCASE_VAR expansion (double-quoted/unquoted only,
    single-quoted values stay literal);
  - command substitution ($(...) / backticks) is rejected — no eval, no RCE.

Intentional, documented divergences (not drift):
  - blocked vars are SKIPPED silently here (server .env is Ansible-generated);
    lib/env.sh fails loudly instead;
  - ENV is allowed because server.env.j2 legitimately writes ENV=.
"""

import os
import re

# Full shell-hijack blocklist, minus ENV (server.env.j2 writes ENV=).
BLOCKED_VARS = re.compile(
    r"^(PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|SHELL|SHELLOPTS|BASHOPTS|"
    r"BASH_FUNC_.*|PS1|PS2|PS3|PS4|TMPDIR|USER|HOME|UID|GID|SHLVL|PPID|"
    r"BASH_VERSION|BASH_SUBSHELL)$"
)

_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
_EXPAND_RE = re.compile(r"\$\{?([A-Z_][A-Z0-9_]*)\}?")
_MAX_EXPANSION = 10


def _expand(value: str) -> str:
    """Expand $VAR/${VAR} refs (uppercase only) with a bounded loop.

    A cyclic/self-referential value (e.g. BAR='$BAR' then FOO=$BAR) would
    otherwise loop forever — cap it, matching the Bash parsers.
    """
    for _ in range(_MAX_EXPANSION):
        m = _EXPAND_RE.search(value)
        if not m:
            break
        var = m.group(1)
        value = value.replace(f"${{{var}}}", os.environ.get(var, ""))
        value = value.replace(f"${var}", os.environ.get(var, ""))
    else:
        raise ValueError("variable expansion limit exceeded in .env")
    return value


def load_env(env_path: str = "") -> None:
    """Parse KEY=VALUE from a .env file, exporting to os.environ.

    Skips empty lines, comments, malformed lines, and blocked security-
    sensitive vars. Values are stripped of surrounding quotes and inline
    comments; double-quoted/unquoted values get $VAR expansion.
    """
    if not env_path:
        env_path = os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.isfile(env_path):
        raise FileNotFoundError(f".env not found: {env_path}")
    try:
        with open(env_path) as f:
            lines = f.read().splitlines()
    except PermissionError:
        raise PermissionError(f"Permission denied: {env_path}") from None

    key = ""
    value = ""
    quote = ""

    def commit(no_expand: bool) -> None:
        nonlocal key, value, quote
        # Reject command substitution in the raw value, then again after
        # expansion (defense-in-depth — a $VAR could itself contain $()).
        if "$(" in value or "`" in value:
            raise ValueError(f"Shell injection pattern detected in {key}")
        if not no_expand:
            value = _expand(value)
            if "$(" in value or "`" in value:
                raise ValueError(f"Shell injection pattern detected in {key}")
        os.environ[key] = value
        key = ""
        value = ""
        quote = ""

    for n, raw in enumerate(lines, 1):
        line = raw
        if quote:
            # Multi-line quoted value — accumulate until the closing quote.
            # Anything after the closing quote on that line is an inline comment.
            if quote in line:
                tail = line.split(quote, 1)[0]
                value += "\n" + tail
                commit(no_expand=(quote == "'"))
            else:
                value += "\n" + line
            continue

        if not line or line.lstrip().startswith("#"):
            continue
        line = line.removeprefix("export ")
        m = _KEY_RE.match(line)
        if not m:
            continue  # malformed line — skip (server-side tolerance)
        key = m.group(1)
        value = m.group(2)
        if BLOCKED_VARS.match(key):
            key = ""
            continue

        # Multi-line quoted value: opening quote without a matching close on
        # this line (trailing whitespace/comments after the close are allowed).
        if value.startswith('"') and not re.match(r'^".*"[ \t]*(#.*)?$', value):
            quote = '"'
            value = value[1:]
            continue
        if value.startswith("'") and not re.match(r"^'.*'[ \t]*(#.*)?$", value):
            quote = "'"
            value = value[1:]
            continue

        no_expand = False
        m1 = re.match(r'^"(.*)"[ \t]*(#.*)?$', value)
        m2 = re.match(r"^'(.*)'[ \t]*(#.*)?$", value)
        if m1:
            value = m1.group(1)
        elif m2:
            value = m2.group(1)
            no_expand = True
        else:
            # Unquoted: strip inline comment (whitespace + #) and trailing ws.
            value = re.split(r"[ \t]+#", value, maxsplit=1)[0].rstrip()
        commit(no_expand)

    if quote:
        raise ValueError(f"Unterminated quoted value for {key} in {env_path} (reached EOF)")
