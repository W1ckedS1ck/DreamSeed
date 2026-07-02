# Code Review: DreamSeed Repository

> Generated: 2026-07-02 (updated after fixes)
> Branch: `dev`

---

## 1. Баги (оставшиеся)

| # | Файл | Строка | Проблема | Серьёзность |
|---|------|--------|----------|-------------|
| 1 | `.github/workflows/grafana-cloud.yml` | 60 | Имя секрета `DEV_GRAFANA_CLOUD_SA_TOKEN` несовместимо с `DEV_GRAFANA_CLOUD_TOKEN` из `deploy.yml`. | High |

**Исправлено:** telegram_bot.py env detection, send_report.sh dead code, RESTORE_ALL.sh double summary, terraform/grafana provisioner, multi-line `.env` parsing.

---

## 2. Лишние / мёртвые файлы (оставшиеся)

| Файл | Примечание |
|------|------------|
| `ansible/requirements.txt` | Заменён на `requirements-deploy.txt`, упоминание в истории git. |

**Удалено:** `terraform.tfvars 2.example`, `secrets/.env.bak.*`, AWS provider 6.51.0, `audit-secrets.sh` (commit).

---

## 3. Логические проблемы (оставшиеся)

| # | Файл | Строки | Проблема |
|---|------|--------|----------|
| 1 | `ansible-roles/monitoring/tasks/_install_binary.yml` | 36 | **Нет checksum verification** — все бинарники скачиваются без SHA256 (supply-chain риск). |
| 2 | `ansible-roles/packages_common/tasks/main.yml` | 17-29 | Пустой fallback PHP версии — `php_version` может стать `""`. |
| 3 | `lib/terraform.sh` | 95 | `mktemp` с хардкодом `/tmp/` — менее портативно. |
| 4 | `lib/env.sh` | 129 | `TF_TOKEN_app_terraform_io` экспортируется с пустым значением если `TF_API_TOKEN` не задан. |
| 5 | `lib/preflight.sh` | 22-24 | `source .env` может перезаписать `DEPLOY_DOMAIN`/`WEB_SERVER`. |
| 6 | `.github/workflows/drift-detection.yml` | 90 | `enable_primary_ip=true` для всех Hetzner (включая dev-hetz с существующим IP) — шум в drift detection. |
| 7 | `.github/workflows/terraform-apply.yml` | 111-112 | Пустой SSH key на Hetzner — apply упадёт. |
| 8 | `.github/workflows/health-check.yml` | 154 | Хардкод `php8.3-fpm` — не совпадёт с авто-детектом PHP версии. |
| 9 | `deploy.sh` | 10 | `PHP_VERSION` — экспортируется, но никогда не передаётся в Ansible (роль сама детектит). |

**Исправлено:** `tmp_bk` cleanup, `[DEBUG]` лог, пустой SSL block, gather_facts cache timeout → 86400, SSL `changed_when`, duplicate `unattended-upgrades`, Cloudflare python subprocesses, Apache locale `changed_when`, PHP version fail, env_loader blocked-vars.

---

## 4. Дублирование

| # | Где | Что дублируется |
|---|-----|-----------------|
| 1 | `backup/tasks/main.yml` vs `restore/tasks/main.yml` | ~25 строк rclone config logic |
| 2 | `deploy.sh:189-197` vs `deploy.sh:457-494` | Порядок плэйбуков (список + parallel-ветвление) — нет валидации |
| 3 | `lib/env.sh:83-91` vs `lib/env.sh:101-117` | Парсинг `ADDITIONAL_SSH_KEYS` для AWS и Hetzner |
| 4 | `monitoring/tasks/check_site.yml` vs `check_services.yml` | ~80% структурного дублирования |
| 5 | `ssl/tasks/main.yml` (restore part) vs `restore/tasks/main.yml` | Логика восстановления SSL-сертификатов частично пересекается |

**Исправлено:** duplicate `unattended-upgrades` install удалён из security-роли.

---

## 5. Проблемы безопасности (оставшиеся)

| # | Файл | Проблема | Серьёзность |
|---|------|----------|-------------|
| 1 | `ansible-roles/monitoring/tasks/_install_binary.yml:36` | Нет checksum verification — supply-chain риск | High |
| 2 | `ansible-roles/apache_http/tasks/main.yml` | Locale-dependent `changed_when` — проверка `"Enabling"` не сработает на не-English системах | Low |
| 3 | `.github/workflows/deploy.yml:161-165` | Хардкод инфраструктурных конфигов (`Vitali.pub`, `cx43`), а не через переменные | Low |

**Исправлено:** 3 plain-text `.env.bak.*` файла вне vault удалены. env_loader.py blocked-var protection.

---

## 6. Хардкод / должно быть переменными

| # | Файл | Что хардкод |
|---|------|-------------|
| 1 | `php/templates/www.conf.j2:11-14` | `pm.start_servers=5`, `pm.min_spare_servers=3`, `pm.max_spare_servers=10` |
| 2 | `mariadb/templates/99-optimizations.cnf.j2:12-15` | `tmp_table_size=64M`, `max_heap_table_size=64M`, `join_buffer_size=2M` |
| 3 | `nginx/templates/nginx.conf.j2:8` | `worker_connections 768` |
| 4 | Все exporter service definitions | Порты `:9100`, `:9104`, `:9121`, `:8428` — хардкод |
| 5 | `ansible-roles/ssl/tasks/main.yml:78-92` | `ssl_staging` undocumented, нет дефолта в `group_vars/all.yml` |

---

## 7. Проблемы производительности (оставшиеся)

| # | Файл | Проблема |
|---|------|----------|
| 1 | `ansible-roles/grafana/files/*.json` | 4 JSON дашборда ~928 KB total в git (не критично, но тяжело для diff) |

**Исправлено:** Cloudflare DNS — 5 отдельных python3 подпроцессов сведено к 2.

---

## 8. Приоритет исправлений

```
[P1] Добавить checksum verification в _install_binary.yml
[P1] Исправить secret name в grafana-cloud.yml
[P3] source .env может перезаписать DEPLOY_DOMAIN
```
