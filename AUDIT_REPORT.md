# Audit Report — DreamSeed Infrastructure

> Generated: 2026-06-03
> Scope: Full codebase audit (deploy, Ansible, Terraform, CI/CD, scripts, templates)
> Total issues found: ~93

---

## 🔴 Critical (7) — все ✅ исправлены

| # | File | Line | Issue |
|---|------|------|-------|
| 1 | `scripts/common_functions.sh` | 100 | `escape_md2()` sed range bug |
| 2 | `ansible-roles/php/templates/php_limits.ini.j2` | 1 | YAML `---` frontmatter в INI |
| 3 | `ansible-roles/backup/templates/server.env.j2` | 21-23 | Пути без кавычек |
| 4 | `ansible-roles/monitoring/templates/check_site.sh.j2` | 48,75-77,87-89,94 | SQL injection через Jinja2 |
| 5 | `ansible-roles/security/templates/sshd-hardening.conf.j2` | 11 | `AllowUsers` без `default()` |
| 6 | `lib/ansible.sh` | 10 | Exit code маскируется `tee` |
| 7 | `.github/workflows/backup-test.yml` | 185-187 | Pipeline без `pipefail` |

---

## 🟠 High (9)

| # | File | Line | Issue | Status |
|---|------|------|-------|--------|
| 8 | `terraform/aws/main.tf`, `terraform/hetzner/main.tf` | 40,30 | SSH открыт в мир (0.0.0.0/0) | 🔴 |
| 9 | `terraform/grafana/sm.tf` | 17,46,72,102,126 | SM checks превышают free tier ×40 (~$60/мес) | 🔴 |
| 10 | `ansible-roles/grafana/tasks/main.yml` | 194-211 | Grafana password drift — marker file | ✅ Info (design choice) |
| 11 | `ansible-roles/monitoring/tasks/check_site.yml` | 2-33 | Нет `become: true` — только play-level | ✅ Fixed |
| 12 | `ansible-roles/backup/tasks/main.yml` | 174,186,198 | `query_result[0][0].cnt` — хрупкая индексация | ✅ Fixed |
| 13 | `ansible-roles/nginx/tasks/main.yml` | 33-39,49-55 | `force: yes` отсутствует на symlink | ✅ Fixed |
| 14 | `terraform/aws/main.tf` | 6-20 | AMI lookup дрифтует (`most_recent = true`) | 🟢 Low (wontfix) |
| 15 | `.github/actions/setup-secrets/action.yml` | 46 | SSH host key = `/dev/null` — MITM | ✅ Fixed |
| 16 | `audit-secrets.sh` | 89-92 | Проверяет только HEAD, не staged | ✅ Fixed |

---

## 🟡 Medium (Top 15)

| # | File | Line | Issue | Status |
|---|------|------|-------|--------|
| 17 | `php/templates/php_limits.ini.j2` | 16 | `cookie_samesite = Lax` | ✅ Info (standard practice) |
| 18 | `php/templates/www.conf.j2` | 10 | `pm.max_children` может быть 0 — нет `max(1)` | ✅ Fixed |
| 19 | `grafana/tasks/main.yml` | 3-10 | GPG key failure silently swallowed (`failed_when: false`) | ✅ Fixed |
| 20 | `ansible/playbook-01-base.yml` | 5 | `gather_facts: false` — `php_version` stale | ✅ Fixed |
| 21 | `lib/preflight.sh` | 26-28 | После `--write-env` source старой декрипт-копии | ✅ Fixed |
| 22 | `ansible-roles/ssl/tasks/main.yml` | 10-19 | `mode: 0755` на restore SSL — ключи 0644 | ✅ Fixed |
| 23 | `monitoring/templates/vmagent.service.j2` | 7 | vmagent под root | ✅ Fixed |
| 24 | `terraform/grafana/outputs.tf` | 20-29 | SM outputs падают при `sm_enabled = false` | ✅ Fixed |
| 25 | `terraform/aws/provider.tf`, `hetzner/provider.tf` | 7 | TFC workspace prefix коллизия | 🟢 Wontfix (design choice) |
| 26 | `.github/workflows/ci.yml` | 63,66 | `terraform_version: latest` | 🟢 Wontfix (design choice) |
| 27 | `deploy.sh` | 258 | Stderr на `/dev/null` — нет контекста ошибки | ✅ Fixed |
| 28 | `mariadb/tasks/main.yml` | 17-18 | `flush_handlers` до hardening | ✅ Fixed |
| 29 | `terraform/grafana/main.tf` | 60-63 | HTTP data source на plan time | ✅ Fixed |
| 30 | `scripts/smart_backup.sh` | 54,120 | `$DOMAIN` не задан — полагается на `.env` | ✅ Fixed |
| 31 | `mariadb/templates/99-optimizations.cnf.j2` | 15-16 | buffer pool без нижней границы | ✅ Fixed |
| 32 | `backup/tasks/main.yml` | 144-154 | Session cleanup cron глотает все ошибки | ✅ Fixed |

---

## 🟢 Low / Refactor (~30+)

- `ansible.cfg:3+13` — `profile_tasks` несовместим со `strategy: free`
- `find -printf | cut -d' ' -f2-` дублируется в 4 скриптах — вынести в `common_functions.sh`
- JSON через bash строки (setup_betteruptime.sh, setup_healthchecks.sh) — нужен `jq`
- `list_betteruptime.sh` — mktemp без `trap cleanup`
- `README.md` — "8 parallel CI jobs", по факту 7
- Grafana dashboard JSONs не в репозитории (live с grafana.com)
- `escape_md2()` баг может дублироваться в `telegram_bot.py`
- Нет `validation` блоков в Terraform variables
- Hardcoded probe locations в `grafana/main.tf`
- `AllowOverride All` в apache http vhost — perf hit

---

## 💡 Improvement Ideas

| Область | Идея |
|---------|------|
| Security | SSH restriction (office/GH runner IPs), SSM Session Manager |
| Security | Hetzner `delete_protection` для prod |
| Security | vmagent под unprivileged user |
| Security | Terraform variable validation blocks |
| Reliability | AMI pinning через `aws_ssm_parameter` + Renovate |
| Reliability | `force: yes` на nginx symlink |
| Reliability | `create_before_destroy` на EIP association |
| Reliability | Grafana dashboards version-controlled в репозитории |
| Reliability | Lockfile для pip (`requirements-deploy.txt.lock`) |
| Observability | SUCCESS_RATE метрика — недельный аплоад (сейчас баг) |
| Observability | VM backup health check с `failed_when: false` |
| Operations | setup_betteruptime.sh переписать на Python |
| Operations | nuclei caching в CI |
| Operations | Split apt install PHP/MariaDB в разные таски |
| Operations | Явный `set -o pipefail` в `_ansible_cmd()` |
| Operations | Accumulate missing vars вместо первого exit |
| Testing | shellcheck `--severity=warning` |
| Testing | Ansible molecule test / `--syntax-check` в CI |
| Testing | Pre-commit hook для проверки .j2 шаблонов |

---

## 🔧 Fixes Applied

| # | File | Fix |
|---|------|-----|
| 1 | `scripts/common_functions.sh:100` | `-` перемещён в конец класса символов sed |
| 2 | `ansible-roles/php/templates/php_limits.ini.j2:1` | Удалён YAML frontmatter `---` |
| 3 | `ansible-roles/backup/templates/server.env.j2:21-23` | Добавлены двойные кавычки вокруг значений |
| 4 | `ansible-roles/monitoring/templates/check_site.sh.j2` | Jinja2-переменные экранированы через `replace("'", "''")` |
| 5 | `ansible-roles/security/templates/sshd-hardening.conf.j2:11` | Добавлен `\| default('ubuntu')` |
| 6 | `lib/ansible.sh:10` | Добавлен `PIPESTATUS[0]` для сохранения exit code |
| 7 | `.github/workflows/backup-test.yml:185-187` | Добавлен `set -o pipefail` |
| 8 | `playbooks 04/05/06` | `become: true` → `become: false` (унификация с 01/02/03/07) |
| 9 | `all monitoring/backup/grafana role tasks` | Добавлен `become: true` (43 задачи) |
| 10 | `nginx/tasks/main.yml`, `nginx-ssl/tasks/main.yml` | Добавлен `force: true` на 3 symlink |
| 11 | `nginx-ssl/handlers/main.yml` | Создан handler `Reload Nginx` (self-contained) |
| 12 | `backup/tasks/main.yml:184,197,209` | `query_result[0][0].cnt` → `query_result[0][0]['cnt']` |
| 13 | `.github/actions/setup-secrets/action.yml:46` | Удалён `UserKnownHostsFile /dev/null` |
| 14 | `.github/workflows/backup-test.yml` | Добавлен step `ssh-keyscan` перед SSH |
| 15 | `audit-secrets.sh:90,92` | `git grep HEAD` → `git grep HEAD --cached` |
| 18 | `ansible-roles/php/templates/www.conf.j2:10` | `pm.max_children` обёрнут в `max(2)` — защита от 0 на малых VM |
| 19 | `ansible-roles/grafana/tasks/main.yml:11` | Удалён `failed_when: false` — GPG key failure не глотается |
| 20 | `ansible/playbook-01-base.yml:5` | `gather_facts: false` → `true` — `php_version` всегда свежий |
| 21 | `lib/preflight.sh:28` | После `--write-env` повторный `resolve_env_file` + source |
| 22 | `ansible-roles/ssl/tasks/main.yml:17` | `mode: "0755"` → `preserve` — приватные ключи не 0644 |
| 23 | `ansible-roles/monitoring/templates/vmagent.service.j2:7` | `User=root` → `User=vmagent` + создан system user в vmagent.yml |
| 24 | `terraform/grafana/outputs.tf:20-28` | SM output обёрнут в `var.sm_enabled ? ... : {}` |
| 27 | `deploy.sh:258` | `2>/dev/null` → `2>&1 | tee -a "$DEPLOY_TF_LOG"` |
| 28 | `ansible-roles/mariadb/tasks/main.yml:17-18` | `flush_handlers` перемещён после hardening (Remove root access) |
| 29 | `terraform/grafana/main.tf` | `data.http` → `terraform_data` + `file()` кэш; `.dashboards/` в `.gitignore` |
| 30 | `scripts/smart_backup.sh:17` | Добавлен `DOMAIN="${DOMAIN:-unknown}"` fallback |
| 31 | `ansible-roles/mariadb/templates/99-optimizations.cnf.j2:15-16` | `innodb_buffer_pool_size`/`innodb_log_file_size` с `| max` нижней границей |
| 32 | `ansible-roles/backup/tasks/main.yml:159` | `2>/dev/null || true` → `2>&1 | logger -t session-cleanup` |
