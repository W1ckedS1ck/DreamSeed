#!/usr/bin/env python3
"""Generate Ansible extra vars JSON for deploy.sh.

Usage: gen_vars.py TARGET SCRIPT_DIR DST

Reads environment variables and writes a JSON file for --extra-vars.
"""
import json
import os
import re
import sys

JINJA_RE = re.compile(r'\{\{.*?\}\}')


def _check_jinja(key, val):
    """Reject extra vars containing Jinja2 delimiters.

    These values are rendered by Ansible in 'content:' / 'template:' blocks,
    so '{{ lookup('pipe', '...') }}' would be remote code execution on the
    server. Every value here comes from trusted local input (target, flags,
    user's own SSH keys), so a Jinja2 delimiter is never legitimate — either
    a bug or an attack. Fail the deploy instead of shipping it.
    """
    if isinstance(val, str) and JINJA_RE.search(val):
        raise SystemExit(
            f"ERROR: extra var '{key}' contains Jinja2 delimiters ({{{{...}}}}) — "
            "would be evaluated as template code by Ansible. Refusing to deploy."
        )
    if isinstance(val, list):
        for i, item in enumerate(val):
            _check_jinja(f"{key}[{i}]", item)


def main():
    target = sys.argv[1]
    script_dir = sys.argv[2]
    dst = sys.argv[3]

    # group_vars/all.yml handles static defaults via lookup('env').
    # Only pass dynamic per-target vars that cannot be expressed in group_vars.
    data = {
        'deploy_env': target,
        'server_ip': os.environ.get('SERVER_IP', ''),
        'web_server': os.environ.get('WEB_SERVER', ''),
        'secrets_dir': f'{script_dir}/secrets',
        'scripts_dir': f'{script_dir}/scripts',
    }
    ssh_key = os.environ.get('SSH_PUBLIC_KEY_PATH', '')
    if ssh_key.strip():
        data['ssh_public_key_path'] = ssh_key.strip()
    additional_keys = os.environ.get('ADDITIONAL_SSH_KEYS', '')
    if additional_keys.strip():
        data['additional_ssh_keys'] = [k.strip() for k in additional_keys.split('\n') if k.strip()]

    for key, val in data.items():
        _check_jinja(key, val)

    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)


if __name__ == '__main__':
    main()
