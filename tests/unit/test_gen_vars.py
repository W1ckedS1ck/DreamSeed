"""Unit tests for lib/gen_vars.py (the Ansible extra-vars generator).

The generator is the trust boundary between deploy.sh and Ansible: it must
reject Jinja2 delimiters (template-injection → remote code execution on the
server) and only emit the per-target variables that cannot live in
group_vars.
"""

from __future__ import annotations

import json
import stat
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "lib"))

import gen_vars  # noqa: E402


def _run(tmp_path: Path, monkeypatch, target: str = "dev-hetz", **env: str) -> dict:
    dst = tmp_path / "vars.json"
    monkeypatch.setattr(sys, "argv", ["gen_vars.py", target, str(ROOT), str(dst)])
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    gen_vars.main()
    return json.loads(dst.read_text(encoding="utf-8"))


def test_check_jinja_rejects_string_and_list_items() -> None:
    with pytest.raises(SystemExit, match="Jinja2 delimiters"):
        gen_vars._check_jinja("key", "{{ lookup('pipe', 'id') }}")

    with pytest.raises(SystemExit, match=r"key\[1\]"):
        gen_vars._check_jinja("key", ["safe", "{{ 7 * 7 }}"])


def test_check_jinja_accepts_plain_values() -> None:
    gen_vars._check_jinja("key", "plain value")
    gen_vars._check_jinja("key", ["one", "two"])
    gen_vars._check_jinja("key", 42)


def test_main_writes_expected_fields_with_owner_only_permissions(
    tmp_path, monkeypatch
) -> None:
    data = _run(
        tmp_path,
        monkeypatch,
        SERVER_IP="203.0.113.7",
        WEB_SERVER="nginx",
        SSH_PUBLIC_KEY_PATH="  /home/runner/.ssh/deploy_key.pub  ",
        ADDITIONAL_SSH_KEYS="ssh-ed25519 AAAA one@host\n\nssh-ed25519 BBBB two@host\n",
    )

    assert data["deploy_env"] == "dev-hetz"
    assert data["server_ip"] == "203.0.113.7"
    assert data["web_server"] == "nginx"
    assert data["secrets_dir"] == f"{ROOT}/secrets"
    assert data["scripts_dir"] == f"{ROOT}/scripts"
    assert data["ssh_public_key_path"] == "/home/runner/.ssh/deploy_key.pub"
    assert data["additional_ssh_keys"] == [
        "ssh-ed25519 AAAA one@host",
        "ssh-ed25519 BBBB two@host",
    ]
    assert "ssl_cf_dns_enabled" not in data

    mode = stat.S_IMODE((tmp_path / "vars.json").stat().st_mode)
    assert mode == 0o600


def test_test_target_disables_cloudflare_dns_cert(tmp_path, monkeypatch) -> None:
    data = _run(tmp_path, monkeypatch, target="test")
    assert data["ssl_cf_dns_enabled"] is False


def test_fail2ban_ignoreip_prefers_target_specific_value(tmp_path, monkeypatch) -> None:
    data = _run(
        tmp_path,
        monkeypatch,
        target="dev-aws",
        FAIL2BAN_IGNOREIP="192.0.2.1",
        FAIL2BAN_IGNOREIP_DEV_AWS="  198.51.100.9   198.51.100.10  ",
    )
    assert data["fail2ban_ignoreip"] == "198.51.100.9 198.51.100.10"


def test_fail2ban_ignoreip_falls_back_to_generic_value(tmp_path, monkeypatch) -> None:
    data = _run(
        tmp_path,
        monkeypatch,
        target="dev-hetz",
        FAIL2BAN_IGNOREIP="192.0.2.1 192.0.2.2",
    )
    assert data["fail2ban_ignoreip"] == "192.0.2.1 192.0.2.2"
