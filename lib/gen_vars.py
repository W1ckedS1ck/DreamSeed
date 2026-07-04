#!/usr/bin/env python3
"""Generate Ansible extra vars JSON for deploy.sh.

Usage: gen_vars.py TARGET SCRIPT_DIR DST

Reads environment variables and writes a JSON file for --extra-vars.
"""
import json
import os
import sys


def main():
    target = sys.argv[1]
    script_dir = sys.argv[2]
    dst = sys.argv[3]

    data = {
        'db_pass': os.environ.get('DB_PASS', ''),
        'server_ip': os.environ.get('SERVER_IP', ''),
        'web_server': os.environ.get('WEB_SERVER', ''),
        'domain': os.environ.get('DEPLOY_DOMAIN', ''),
        'domain_www': target.startswith('prod'),
        'cloudflare_enabled': target.startswith('prod'),
        'secrets_dir': f'{script_dir}/secrets',
        'configs_dir': f'{script_dir}/configs',
        'scripts_dir': f'{script_dir}/scripts',
        'deploy_env': target,
    }

    optional_map = {
        'CLOUDFLARE_API_TOKEN': 'cloudflare_api_token',
        'GRAFANA_PASS': 'grafana_admin_password',
        'SSH_PUBLIC_KEY_PATH': 'ssh_public_key_path',
        'GRAFANA_CLOUD_URL': 'grafana_cloud_url',
        'GRAFANA_CLOUD_USERNAME': 'grafana_cloud_username',
        'GRAFANA_CLOUD_TOKEN': 'grafana_cloud_token',
    }
    for env_var, key in optional_map.items():
        val = os.environ.get(env_var)
        if val:
            data[key] = val

    additional_keys = os.environ.get('ADDITIONAL_SSH_KEYS', '')
    if additional_keys.strip():
        data['additional_ssh_keys'] = [k.strip() for k in additional_keys.split('\n') if k.strip()]

    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)


if __name__ == '__main__':
    main()
