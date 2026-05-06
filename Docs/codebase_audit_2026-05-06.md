# Аудит кодовой базы DreamSeed — 06.05.2026

## АРХИТЕКТУРНЫЕ ПРОБЛЕМЫ

### 1. [CRITICAL] Дублирование bot_handler.sh и telegram_bot.py — полная функциональная копия

Оба файла делают одно и то же: `/status` и `/backups` через Telegram. На сервере работает **только** `telegram_bot.py` (через systemd `telegram-bot.service`). `bot_handler.sh` — мёртвый код, не вызывается нигде.

**Проблемы:**
- При изменении логики нужно править два файла
- `bot_handler.sh` содержит баг: `MSG+=""` внутри пайпа `while read` не работает (subshell)
- Форматирование имён иSizes дублировано

**Действие:** Удалить `bot_handler.sh` из `scripts/` и из `backup/tasks/main.yml` (upload loop)

### 2. [CRITICAL] Дублирование environment detection — 6 файлов, одинаковый блок

Шаблон `HOSTNAME=$(hostname); case ...` повторяется в **6 скриптах**:
- `smart_backup.sh`
- `upload_backups_to_gdrive.sh`
- `daily_report.sh`
- `weekly_report.sh`
- `bot_handler.sh` (мёртвый)
- `RESTORE_ALL.sh`

**Действие:** Вынести в `common_functions.sh`:
```bash
detect_env() {
    local hostname
    hostname=$(hostname)
    case "$hostname" in
        *-prod|*prod-*)  echo "prod"; return ;;
        *)               echo "preprod"; return ;;
    esac
}
```
И вызывать `ENV=$(detect_env)` в каждом скрипте.

### 3. [CRITICAL] Дублирование get_size / format_name — 3 разных реализации

- `smart_backup.sh`: нет get_size (простой)
- `bot_handler.sh`: `get_size()` через `stat -c %s` (bash)
- `telegram_bot.py`: `get_size()` через `os.path.getsize` (python)
- `daily_report.sh`: `format_name()` через sed
- `weekly_report.sh`: `format_name()` через sed (идентичная)
- `telegram_bot.py`: `format_proj_name()` / `format_db_name()` (python, аналогичная логика)

**Действие:** Вынести `get_size()` и `format_name()` в `common_functions.sh`, в Python импортировать через subprocess или переписать бота с вызовом shell-функций.

### 4. [HIGH] monitoring user = тот же пароль что modx_user

`mariadb/tasks/main.yml:56` — monitoring user создаётся с `password: "{{ db_pass }}"`. Два разных пользователя БД с одинаковым паролем + monitoring имеет PROCESS/REPLICATION CLIENT/SELECT на **всех** базах.

**Действие:** Создать отдельную переменную `db_monitoring_pass` с уникальным паролем. Ограничить права monitoring конкретной БД или только `mysql.*`.

### 5. [HIGH] PHP hardening: php_limits.ini.j2 vs реальный сервер

Шаблон `php_limits.ini.j2` содержит:
```ini
disable_functions = eval,shell_exec,system,passthru,proc_open,popen,pcntl_exec,phpinfo
```
Но на сервере `php -i` показывает `disable_functions = no value`. Причина: файл деплоится в `/etc/php/8.3/fpm/conf.d/50-limits.ini`, но **PHP CLI** не читает fpm conf.d. А FPM показывает `no value` — значит что-то перезаписывает или файл не загрузился.

Также отсутствуют:
- `open_basedir`
- `session.cookie_httponly`
- `session.cookie_samesite`
- `expose_php = Off`

**Действие:** Добавить недостающие директивы в шаблон + добавить CLI override + проверить почему FPM не подхватывает.

### 6. [HIGH] Grafana: lineinfile вместо шаблона

`monitoring/tasks/grafana.yml:48-68` — 13 директив настраиваются через `lineinfile`. Это хрупко:
- Не создаёт секции если их нет
- Может сломать многострочные значения
- Не управляет порядком строк
- `secret_key` не устанавливается (критично для шифрования)

**Действие:** Переписать на `ansible.builtin.template` с полным `grafana.ini.j2`.

### 7. [HIGH] Нет defaults/main.yml ни в одной роли

Ни одна из 14 ролей не имеет `defaults/main.yml`. Все переменные берутся из `group_vars/all.yml` или extra-vars. Это значит:
- Роль нельзя протестировать изолированно
- Нет документации какие переменные роль ожидает
- При опечатке в имени переменной — тихий fail

**Действие:** Создать `defaults/main.yml` в каждой роли с документацией и fallback-значениями.

---

## МАСШТАБИРУЕМОСТЬ

### 8. [HIGH] Жёсткая привязка к одному серверу

Весь проект рассчитан на 1 инстанс: 1 хост `dreamseed`, 1 inventory, 1 домен. При масштабировании:
- Inventory — статический YAML, не поддерживает динамическое обнаружение
- Нет поддержки нескольких серверов (web + db separate)
- Grafana dashboards деплоятся как статичные JSON (35K строк) — не параметризованы
- Telegram bot запускается как `User=ubuntu` — один на сервер

**Действие:**
- Перейти на AWS dynamic inventory (`amazon.aws.aws_ec2`)
- Вынести `inventories/` с отдельными файлами per-environment (уже частично есть, но не используются деплоером)
- Параметризовать dashboards UID через templates

### 9. [MEDIUM] VictoriaMetrics retention захардкожен

`victoria-metrics.service.j2:10` — `-retentionPeriod=1` (1 месяц). Не переменная.

**Действие:** Вынести в `defaults/main.yml` → `vm_retention: 3` → template.

### 10. [MEDIUM] Grafana version захардкожена

`grafana.yml:41` — `grafana=12.4.3`. На сервере уже 12.4.3, а в apt доступна 13.0.1.

**Действие:** Вынести в переменную `grafana_version: "12.4.3"` в defaults.

### 11. [MEDIUM] Grafana dashboards — 35K строк статичного JSON в git

6 файлов JSON (node-exporter-full.json = 18K строк) хранятся в `monitoring/files/`. При обновлении Grafana или изменении datasource — нужно править вручную.

**Действие:** Рассмотреть:
- Grafana dashboard as code (jsonnet/grafonnet)
- Или хотя бы template с подстановкой `datasourceUid`

---

## КАЧЕСТВО КОДА

### 12. [HIGH] deploy.sh: 717 строк, 1 файл

Монолитный скрипт. Функции не сгруппированы в модули. Сложно тестировать и поддерживать.

**Действие:** Разбить на `lib/`:
- `lib/targets.sh` — resolve_target, apply_target_vars
- `lib/terraform.sh` — init, apply, destroy, workspace
- `lib/ansible.sh` — run_ansible, generate_inventory
- `lib/ui.sh` — step_start/ok/fail, spinner, format_time
- `lib/validate.sh` — preflight_checks, validate_env_file

### 13. [HIGH] RESTORE_ALL.sh: eval для динамической переменной

`RESTORE_ALL.sh:108`: `eval "$result_var=$selected"` — это небезопасно, позволяет инъекцию через имя файла.

**Действие:** Использовать `declare -g` или nameref:
```bash
declare -g "$result_var"="$selected"
```

### 14. [HIGH] smart_backup.sh: hash-based project backup = только 1 копия

Hash-skip означает, что проектный бэкап пропускается если файлы не изменились. На сервере сейчас **1 копия** проекта с 3 мая (8 дней). Для production это неприемлемо.

**Действие:** Бэкап проекта — всегда (как DB), hash-skip убрать или сделать опциональным.

### 15. [MEDIUM] smart_backup.sh: rotate_files — word splitting

`rotate_files()` использует `ls -1t $pattern` без кавычек — word splitting на именах с пробелами (не актуально сейчас, но ломает масштабируемость).

**Действие:**
```bash
mapfile -t files < <(ls -1dt $pattern 2>/dev/null)
```

### 16. [MEDIUM] common_functions.sh: bare `source` без защиты

`load_env()` делает `source "$env_file"` — если .env содержит команды типа `rm -rf /`, они выполнятся.

**Действие:** Парсить .env построчно (как в `telegram_bot.py`), а не source:
```bash
load_env() {
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && export "$key=$value"
    done < "$1"
}
```

### 17. [MEDIUM] telegram_bot.py: bare except, нет logging

- `except:` (строки 47, 79, 94) — глушит ВСЕ ошибки включая KeyboardInterrupt
- Нет logging модуля — `print(f"Error: {e}")` не попадает в journalctl корректно
- Нет `/healthcheck` эндпоинта для мониторинга самого бота

**Действие:** Заменить `except:` на `except Exception:`, добавить `logging`, добавить healthcheck.

### 18. [MEDIUM] telegram_bot.py: нет авторизации входящих сообщений

Любой пользователь может отправить `/status` боту, и бот ответит в `TG_CHAT_ID` с данными о бэкапах. Нет проверки `chat_id == TG_CHAT_ID` для входящих.

**Действие:** Добавить фильтр:
```python
if chat_id != int(TG_CHAT_ID):
    continue  # ignore messages from unknown chats
```

### 19. [LOW] PHP FastCGI конфиг дублирован 3 раза в vhost-ssl.conf.j2

Блок `location ~ \.php$` повторяется:
1. В корне сервера (строка 65)
2. В `location ^~ /manager` (строка 52)
3. В `vhost.conf.j2` (HTTP) — ещё раз

**Действие:** Вынести в snippet (`/etc/nginx/snippets/modx-php.conf`) и `include`.

### 20. [LOW] upload_backups_to_gdrive.sh: DELETED_COUNT не используется

Строка 88: `DELETED_COUNT=0` и инкремент — но переменная нигде не читается.

**Действие:** Удалить или добавить в отчёт.

---

## БЕЗОПАСНОСТЬ КОДА

### 21. [CRITICAL] .my.cnf с паролем в plaintext

`mariadb/templates/my.cnf.j2` деплоит `~ubuntu/.my.cnf` с `password={{ db_pass }}`. MariaDB exporter тоже в `exporter.cnf`. Оба файла — plaintext пароли.

**Действие:** Рассмотреть `mysql_config_editor` для обфускации (не шифрование, но лучше plaintext).

### 22. [HIGH] .gitignore исключает *.service — но они в ansible-roles/templates

`*.service` в .gitignore исключает все .service файлы. Это правильно для секретов, но `scripts/telegram_bot.service` и `scripts/telegram-bot.service` — это исходники, не секрета. Они деплоятся через template, но исходники git должен видеть.

**Действие:** Уточнить `.gitignore` — исключать только в `secrets/`, а не глобально.

### 23. [HIGH] SSH: hardcoded ключ в security role

`security/tasks/main.yml:81` — SSH ключ захардкожен в роль:
```yaml
key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...Uft 2024@DESKTOP-6ADBQSM"
```
Это нельзя поменять без редактирования роли.

**Действие:** Вынести в переменную `additional_ssh_keys: []` в `defaults/main.yml`.

### 24. [MEDIUM] Hetzner TF: NOPASSWD:ALL для ubuntu

`terraform/hetzner/main.tf:93`:
```bash
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu
```
Полный беспарольный sudo — стандартно для AWS, но лучше ограничить.

### 25. [MEDIUM] SSL role: cloudflare.ini с API-токеном

`ssl/tasks/main.yml:76-82` — CloudFlare API token записывается в `/etc/letsencrypt/cloudflare.ini` mode 0600. После получения сертификата файл не удаляется.

**Действие:** Добавить задачу: удалить `cloudflare.ini` после certbot (если auto-renewal использует DNS plugin, то нельзя удалять — но можно ограничить права).

### 26. [MEDIUM] SSL role: нет ssl_dhparam, нет OCSP stapling

Nginx SSL конфиг не включает:
- DH parameters (нет файла `dhparam.pem`)
- OCSP stapling
- `ssl_session_tickets off`

**Действие:** Добавить в `vhost-ssl.conf.j2`:
```nginx
ssl_dhparam /etc/nginx/dhparam.pem;
ssl_stapling on;
ssl_stapling_verify on;
ssl_session_tickets off;
```

---

## TERRAFORM

### 27. [HIGH] Нет remote backend для Terraform state

Terraform state хранится локально (`terraform.tfstate` в каждой директории). Это:
- Небезопасно (содержит секреты в plaintext: IP, resource IDs)
- Не поддерживает командную работу
- Нет блокировки от параллельного применения

**Действие:** Настроить S3 backend + DynamoDB lock для AWS, S3/MinIO для Hetzner:
```hcl
backend "s3" {
  bucket = "dreamseed-tfstate"
  key    = "aws/prod/terraform.tfstate"
  region = "us-west-1"
  encrypt = true
}
```

### 28. [MEDIUM] Нет variables.tf в AWS main.tf

Все переменные AWS определены в `main.tf` вместе с ресурсами. Это затрудняет обзор входных параметров.

**Действие:** Вынести в `variables.tf`, `outputs.tf`, `providers.tf` (стандартная структура).

### 29. [MEDIUM] Hetzner: IPv6 отключен

`main.tf:83` — `# ipv6_enabled = true` закомментирован. Hetzner firewall rules — IPv4 only.

**Действие:** Включить IPv6 + добавить firewall rules для IPv6 (`::/0`).

### 30. [LOW] AWS SG: SSH от 0.0.0.0/0 с tfsec:ignore

Правильнее ограничить SSH по IP. tfsec ignore — это технический долг.

---

## ANSIBLE

### 31. [HIGH] become: false на playbook-02-web, 03-db, 05-security

Playbooks 02-05 имеют `become: false`, но **каждая задача** внутри ролей использует `become: true`. Это означает:
- Каждая задача имеет оверхед на become escalation
- Логика доступа размазана по ролям
- Легко забыть `become: true` на новой задаче

**Действие:** Установить `become: true` на уровне playbook для 02-05 (как уже сделано в 04-monitor).

### 32. [MEDIUM] packages_common: apt-get clean через shell

`packages_common/tasks/main.yml:46`:
```yaml
- ansible.builtin.shell: apt-get clean
```
Эквивалентная Ansible-идиома: `ansible.builtin.apt: clean: yes` (с Ansible 2.14+).

### 33. [MEDIUM] swap: dd вместо fallocate

`packages_common/tasks/main.yml:57`: `dd if=/dev/zero of=/swapfile bs=1M count=2048` — медленно (2GB пишутся побайтно).

**Действие:** `fallocate -l 2G /swapfile` — мгновенно на современных FS.

### 34. [MEDIUM] packages_common: PHP version detection — race condition

`packages_common/tasks/main.yml:9-18`: PHP version detected через shell и set_fact. Но playbook-01 имеет `gather_facts: false` — значит факт не будет доступен в других playbooks без `cacheable: true`.

**Действие:** Использовать `cacheable: true` (уже есть) + включить `fact_caching = jsonfile` в ansible.cfg.

### 35. [LOW] restore role: rclone lsf путь — жёстко "DreamSeed/backups"

`restore/tasks/main.yml:26`: `rclone lsf gdrive:DreamSeed/backups/project/` — захардкожен GDrive путь. Не совпадает с upload скриптом который использует `$REMOTE_BASE/project${ENV}/`.

**Действие:** Параметризовать через переменные.

---

## CI/CD

### 36. [MEDIUM] CI не проверяет Python скрипты

`.github/workflows/ci.yml` — нет ruff/flake8/pylint для `scripts/telegram_bot.py` и `scripts/test_mail.py`.

**Действие:** Добавить job:
```yaml
python-lint:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - run: pip install ruff && ruff check scripts/
```

### 37. [MEDIUM] CI: tflint --init может не найти плагины

`tflint --init` запускается без `--chdir`, может не найти конфиг плагинов.

**Действие:** Запускать `tflint --init --chdir=terraform/aws` для каждого провайдера.

---

## МЁРТВЫЙ КОД / ЛИШНЕЕ

### 38. [HIGH] Удалить мёртвые файлы

| Файл | Причина |
|---|---|
| `scripts/bot_handler.sh` | Дублирует telegram_bot.py, не используется |
| `scripts/telegram_bot.service` | Старый сервис-файл (без EnvFile), используется template |
| `scripts/test_mail.py` | Одноразовый тест, не нужен в production |
| `scripts/test_tg.sh` | Одноразовый тест |
| `scripts/loadtest.sh.j2` | Dev-утилита, не должна деплоиться на prod |
| `configs/fail2ban/jail.local` | Дублирует `security/templates/fail2ban-custom.jail.j2` — один источник истины |
| `Docs/promote_feature_notes.md` | Отменённая фича, нет смысла хранить |
| `deploy.txt` | Дублирует CLAUDE.md и README — один источник истины |
| `terraform/cloudV2/` | Частный провайдер, недоступен из CI, не протестирован |

### 39. [MEDIUM] backup role: upload .env полностью на сервер

`backup/tasks/main.yml:55-61`: Весь `.env` копируется на сервер в `/home/ubuntu/Scripts/.env` mode 0600. Это включает AWS-ключи, CloudFlare токен, и т.д. — всё что нужно серверу НЕ нужно для бэкапов.

**Действие:** Создать отдельный `.env.scripts` только с: `DB_NAME`, `DB_PASS`, `TG_TOKEN`, `TG_CHAT_ID`, `TG_THREAD_ID`, `GDRIVE_BASE`, `BOT_USERNAME`, `OWNER`.

### 40. [MEDIUM] Дублирование: два telegram service файла

- `scripts/telegram_bot.service` — с EnvironmentFile (новый)
- `scripts/telegram-bot.service` — без EnvFile (старый)
- На сервере работает `telegram-bot.service` (из Ansible template)

**Действие:** Удалить оба из `scripts/`, оставить только template в `backup/templates/telegram_bot.service.j2`.

---

## ПРИОРИТЕТНЫЙ ПЛАН

### Немедленно (0-3 дня)
1. Удалить мёртвый код: `bot_handler.sh`, старые `.service`, `test_*.py/sh`, `jail.local`
2. Вынести env detection в `common_functions.sh`
3. Создать `defaults/main.yml` во всех 14 ролях
4. Исправить `become: true` на уровне playbook
5. Добавить `open_basedir`, `cookie_httponly`, `expose_php=Off` в php_limits.ini.j2
6. Вынести SSH ключ из security role в переменную
7. Исправить `load_env()` — парсинг вместо source

### Эта неделя (3-7 дней)
8. Удалить hash-skip из smart_backup.sh
9. Переписать Grafana конфиг на template вместо lineinfile
10. Создать отдельный `.env.scripts` для сервера (без AWS ключей)
11. Вынести VM retention и Grafana version в переменные
12. Добавить DH params + OCSP stapling в nginx-ssl template
13. Разбить deploy.sh на модули

### Этот месяц
14. Настроить Terraform remote backend (S3)
15. Перейти на AWS dynamic inventory
16. Добавить Python linting в CI
17. Параметризовать restore role (GDrive paths)
18. Вынести PHP FastCGI конфиг в snippet
19. Заменить bare `except:` в telegram_bot.py
20. Добавить авторизацию chat_id в боте

---

*Аудит выполнен: 06.05.2026*
*Проект: DreamSeed — Infrastructure as Code*
*Файлов проанализировано: ~60*
*Проблем выявлено: 40 (5 critical, 14 high, 14 medium, 7 low)*
