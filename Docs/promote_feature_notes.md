---
name: Promote feature - попытка и отсутствие решения
description: Попытка реализовать promote dev→prod через GDrive. Отменено из-за конфликта БД.
type: project
originSessionId: 972602a0-e7b4-4881-9f98-a2ebbf29dee9
---
## Проблема

Изначально хотели сделать `/prepare-promote` (dev) и `/promote` (prod) для переноса редизайна с препрода на прод.

**Но:** prod БД содержит реальные данные (покупки, пользователи), а preprod БД другая. Копирование БД preprod→prod потеряет все реальные данные. **Недопустимо.**

## Что было сделано (нужно откатить)

### Новые файлы (удалить):
- `scripts/promote.sh` — скрипт переноса на prod
- `scripts/prepare-for-promote.sh` — подготовка на dev

### Изменения в коде (откатить):
- `scripts/telegram_bot.py` — добавил `cmd_prepare_promote()`, `cmd_promote()`, добавил команды в dispatch
- `ansible-roles/backup/tasks/main.yml` — добавил promote.sh и prepare-for-promote.sh в список скриптов

### На серверах (удалить):
- prod: `~/Scripts/promote.sh`, `~/Scripts/prepare-for-promote.sh`
- prod: `~/.ssh/Vitali.pem` — **приватный ключ (уязвимость!)**
- dev: `~/Scripts/prepare-for-promote.sh`

## Правильное решение (если вернуться)

Нужно копировать **только файлы** (код, шаблоны), а не БД:
- Разраб редизайнит на preprod
- Копируем файлы preprod→prod (rsync без core/config)
- БД prod остаётся нетронутой → реальные данные сохранены
- Новый дизайн работает с реальными данными

Но это отдельная задача. Сейчас откатываем.
