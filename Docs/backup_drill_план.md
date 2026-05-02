# Backup Integrity Test (Backup Drill) — план

## Зачем

Сейчас у нас:
- `smart_backup.sh` кладёт архивы в `/home/ubuntu/backups/`
- `upload_backups_to_gdrive.sh` шлёт их в Google Drive
- `RESTORE_ALL.sh` есть на случай катастрофы

Проблема: **путь restore ни разу не прогоняется до реального инцидента**. Есть гарантия «файлы создаются», нет гарантии «бэкапы восстанавливаются». Drill закрывает эту дыру.

---

## Дизайн — три уровня глубины

### Уровень 1. Smoke-валидация (ежедневно, 30 секунд)

Лёгкая проверка свежесозданного бэкапа прямо после `smart_backup.sh`, до отправки в GDrive.

**`scripts/verify_backup.sh`:**
```bash
set -euo pipefail

LATEST_TAR="$(ls -t /home/ubuntu/backups/project/*.tar.gz | head -1)"
LATEST_SQL="$(ls -t /home/ubuntu/backups/db/*.sql.gz | head -1)"

# 1. Tar не битый
tar -tzf "$LATEST_TAR" > /dev/null

# 2. SQL-дамп полный (есть маркер конца)
zcat "$LATEST_SQL" | tail -5 | grep -q "Dump completed"

# 3. Размер в пределах нормы (±30% от среднего за 7 дней)
AVG=$(ls -l /home/ubuntu/backups/project/*.tar.gz | awk '{sum+=$5; n++} END {print sum/n}')
SIZE=$(stat -c%s "$LATEST_TAR")
python3 -c "exit(0 if abs($SIZE - $AVG) / $AVG < 0.3 else 1)"

# 4. SQL содержит ожидаемые таблицы MODX
zcat "$LATEST_SQL" | grep -q "CREATE TABLE.*modx_site_content"
zcat "$LATEST_SQL" | grep -q "CREATE TABLE.*modx_users"
```

При падении — Telegram: `❌ Backup corrupt: sql dump truncated`. Ловит 80% проблем мгновенно.

### Уровень 2. Полная репетиция (еженедельно, 5 минут, ~2 цента)

Воскресной ночью:
1. Terraform поднимает одноразовый инстанс (Hetzner CX11, ~€0.002 за прогон)
2. Скачивает последний бэкап из GDrive
3. Прогоняет `RESTORE_ALL.sh`
4. Smoke-тесты (см. ниже)
5. Terraform destroy
6. Отчёт в Telegram + метрики в VictoriaMetrics

**`scripts/backup_drill.sh`:**
```bash
TARGET_IP=$1
START=$(date +%s)

# a) MODX вообще поднялся
curl -fsS "http://$TARGET_IP/" | grep -q "<html"

# b) Админка отвечает
[ "$(curl -s -o /dev/null -w '%{http_code}' http://$TARGET_IP/manager/)" = "200" ]

# c) В БД есть контент
ROWS=$(ssh ubuntu@$TARGET_IP "mysql -u root modx_db -sNe 'SELECT COUNT(*) FROM modx_site_content'")
[ "$ROWS" -gt 50 ] || { echo "Too few pages: $ROWS"; exit 1; }

# d) Критичная страница доступна
curl -fsS "http://$TARGET_IP/contact/" | grep -q "известный_текст"

# e) RTO
DURATION=$(( $(date +%s) - START ))
echo "RTO: ${DURATION}s"
```

**Telegram-отчёт при успехе:**
```
✅ Backup drill passed
├ backup: 2026-04-22 (age 18h)
├ restore time: 4m 32s  ← RTO
├ pages in DB: 1247
├ admin: 200 OK
├ homepage: 200 OK
└ cost: €0.002
```

**При падении:**
```
❌ Backup drill FAILED
├ backup: 2026-04-22
├ failed at: step (c) — DB import
├ error: ERROR 1064 at line 8293
└ logs: https://...
```

### Уровень 3. Chaos day (раз в месяц, вручную)

Восстанавливаете бэкап **7-дневной давности**. Цель: убедиться, что retention работает, старые бэкапы не протухли, RPO=7d достижим.

---

## Интеграция с GitHub Actions

### Три варианта

**A. GH Actions как планировщик + runner** (стартуем с этого)
GH по расписанию сам поднимает инстанс, качает бэкап, восстанавливает, разрушает. Всё видно в Actions tab.

**B. Cron на monitoring-хосте + уведомление в GitHub**
Drill крутится локально. При падении создаётся GitHub Issue. Секреты не уезжают в GH.

**C. Self-hosted runner** (финальная версия)
GH Actions триггерит, код исполняется на monitoring-хосте. Секреты не покидают инфру. Production-grade.

### Workflow (вариант A)

**`.github/workflows/backup-drill.yml`:**
```yaml
name: Weekly Backup Drill
on:
  schedule:
    - cron: '0 3 * * 0'     # воскресенье 03:00 UTC
  workflow_dispatch: {}      # кнопка "запустить вручную"

jobs:
  drill:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: pip install ansible

      - name: Configure rclone
        run: |
          mkdir -p ~/.config/rclone
          echo "${{ secrets.RCLONE_CONF }}" > ~/.config/rclone/rclone.conf

      - name: Provision ephemeral test VM
        env:
          HCLOUD_TOKEN: ${{ secrets.HETZNER_TOKEN }}
        run: |
          cd terraform/backup-test
          terraform init && terraform apply -auto-approve
          echo "TEST_IP=$(terraform output -raw ip)" >> $GITHUB_ENV

      - name: Download latest backup from GDrive
        run: rclone copy gdrive:/backups/latest ./backup/

      - name: Restore + smoke-test
        env:
          SSH_KEY: ${{ secrets.SSH_KEY }}
        run: |
          echo "$SSH_KEY" > /tmp/key && chmod 600 /tmp/key
          ./scripts/backup_drill.sh "$TEST_IP"

      - name: Notify Telegram (success)
        if: success()
        env:
          TG_TOKEN: ${{ secrets.TG_TOKEN }}
          TG_CHAT:  ${{ secrets.TG_CHAT }}
        run: ./scripts/notify_telegram.sh "✅ weekly drill passed"

      - name: Open issue on failure
        if: failure()
        uses: JasonEtco/create-an-issue@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          filename: .github/ISSUE_TEMPLATE/drill-failed.md

      - name: Teardown (always)
        if: always()
        env:
          HCLOUD_TOKEN: ${{ secrets.HETZNER_TOKEN }}
        run: |
          cd terraform/backup-test
          terraform destroy -auto-approve
```

### GH Secrets (Settings → Secrets and variables → Actions)

- `HETZNER_TOKEN` — для поднятия VM
- `SSH_KEY` — приватный ключ для доступа к ephemeral-инстансу
- `RCLONE_CONF` — конфиг rclone (весь файл как одна переменная)
- `TG_TOKEN`, `TG_CHAT` — Telegram

**Никогда не логировать их в workflow.**

### Бейдж в README

```markdown
![Backup Drill](https://github.com/VitaliKuts/DreamSeed/actions/workflows/backup-drill.yml/badge.svg)
```

---

## Метрики = портфолио-золото

Каждый прогон пишет в VictoriaMetrics:
```
backup_restore_duration_seconds 272
backup_restore_success 1
backup_age_hours 18
backup_pages_count 1247
```

В Grafana — дашборд **«Disaster Recovery»**:
- **RTO** (mean restore time): линия на графике, аларм если > 10 минут
- **RPO** (backup age): аларм если свежайший бэкап > 26 часов
- Success rate drill'ов за 90 дней

На собеседовании: «RTO 4 минуты, RPO 24 часа, подтверждённые еженедельными drill-тестами на отдельной инфре» — сильнее, чем у 95% мидлов.

---

## Новые файлы в проекте

```
scripts/
├── verify_backup.sh                # уровень 1, вызывается из smart_backup.sh
├── backup_drill.sh                 # уровень 2, smoke-тесты после restore
├── backup_drill_orchestrator.sh    # уровень 2, полный пайплайн (для cron-варианта)
└── notify_telegram.sh              # утилита

terraform/backup-test/
├── main.tf                         # ephemeral CX11 инстанс
├── variables.tf
└── outputs.tf

.github/
├── workflows/
│   ├── ci.yml                      # линтеры (уже в плане GH CI)
│   ├── backup-drill.yml            # drill
│   └── cleanup-orphan-vms.yml      # ежедневная уборка забытых инстансов
└── ISSUE_TEMPLATE/
    └── drill-failed.md             # шаблон автосоздаваемого issue
```

---

## Нюансы

**Trap destroy — защита от забытых VM.** `if: always()` на шаге destroy — обязательно. Плюс отдельный cleanup workflow: раз в день грохает инстансы с тегом `Purpose=drill` старше 2 часов.

**GH schedule лагает** до 15 минут под нагрузкой. Для еженедельного drill не критично.

**Free tier.** Публичный репо = **бесплатно без лимитов**. Приватный = 2000 минут/мес (drill ~10 мин → хватит на 200 прогонов).

**Размер бэкапа.** Если > 5 GB — GH-runner качает долго. Решения: (a) rclone с параллельностью, (b) переход на self-hosted runner (вариант C), (c) drill-light еженедельно + drill-full ежемесячно.

**MODX-специфика после restore** (проверить, что `RESTORE_ALL.sh` это делает):
- `chown -R www-data:www-data /var/www/html`
- Почистить `core/cache/*`
- Поправить `core/config/config.inc.php` (хардкод URL и путей)
- Обновить `site_url` в таблице `modx_system_settings`

**Никогда не тестировать drill на prod-окружении.** Только ephemeral.

---

## Чеклист внедрения

- [ ] `scripts/verify_backup.sh` + подключить в `smart_backup.sh`
- [ ] `scripts/backup_drill.sh` (smoke-тесты)
- [ ] `terraform/backup-test/` (модуль ephemeral-инстанса)
- [ ] `scripts/notify_telegram.sh`
- [ ] `.github/workflows/backup-drill.yml`
- [ ] `.github/workflows/cleanup-orphan-vms.yml`
- [ ] `.github/ISSUE_TEMPLATE/drill-failed.md`
- [ ] GH Secrets: HETZNER_TOKEN, SSH_KEY, RCLONE_CONF, TG_TOKEN, TG_CHAT
- [ ] Бейдж в README
- [ ] Дашборд «Disaster Recovery» в Grafana
- [ ] Первый ручной прогон через `workflow_dispatch`
- [ ] Дождаться первого автоматического запуска в воскресенье

---

## Трудозатраты

~4–6 часов (вечер-два).

## Outcome

- Killer feature в портфолио («бэкапы я верифицирую, а не молюсь»)
- Измеримые RTO/RPO — редко кто может их назвать числом
- Grafana-дашборд, как у взрослых SRE
- Реальная уверенность в собственных бэкапах
- Зелёные чекмарки в Actions tab как публичное доказательство
