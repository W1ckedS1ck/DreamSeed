# GitHub + CI — план на завтра

## Зачем это нужно

Портфолио = публичная ссылка, которую открывает рекрутер. Сейчас проект лежит на `/Users/Vitali_Kuts/Desktop/`, его никто не видит. GitHub Actions нужен **не разработчику, а вам** как владельцу IaC-кода.

### Две разные системы (не путать)

**Workflow разработчика** — не трогаем:
```
Разраб → FTP → preprod-сервер → MODX
```

**Ваш workflow как DevOps** — тут живёт GitHub:
```
Правки Terraform/Ansible → git push → GitHub Actions → lint/validate → merge
```

Это код проекта DreamSeed (`deploy.sh`, `terraform/`, `ansible-roles/`). Разработчику git не нужен — он работает с CMS-файлами, не с инфраструктурой.

---

## Что увидит рекрутер

1. `github.com/VitaliKuts/DreamSeed` — публичный репо
2. README с диаграммой + бейдж `CI: passing` ✅
3. Actions tab → зелёные пайплайны: tflint, ansible-lint, tfsec, shellcheck, gitleaks
4. Осмысленные коммиты в истории
5. Демонстрационный PR с автоматическими проверками

Это превращает проект из «у меня есть опыт» в «вот ссылка, смотрите сами».

---

## Пошаговый план

### Шаг 0 — ПЕРЕД push: скан секретов

**Критично.** В публичный репо нельзя залить:
- `secrets/.env`
- `terraform/*/terraform.tfstate*`
- SSH-ключи
- Cloudflare/Telegram/AWS токены

Проверить:
```bash
cd /Users/Vitali_Kuts/Desktop/DreamSeed
cat .gitignore                          # что уже игнорируется
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:latest detect --source=/repo --verbose
```

Если gitleaks что-то нашёл — **ротировать токен** и добавить в `.gitignore`, ДО первого push.

### Шаг 1 — создать репо и залить

```bash
cd /Users/Vitali_Kuts/Desktop/DreamSeed
git init
git add .
git status                              # ещё раз глазами проверить, что нет секретов
git commit -m "initial import"
# создать пустой репо на github.com/VitaliKuts/DreamSeed (public)
git remote add origin git@github.com:VitaliKuts/DreamSeed.git
git branch -M main
git push -u origin main
```

### Шаг 2 — создать `.github/workflows/ci.yml`

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Terraform lint
        uses: terraform-linters/setup-tflint@v4
      - run: tflint --recursive

      - name: Terraform security scan
        uses: aquasecurity/tfsec-action@v1.0.3

      - name: Ansible lint
        uses: ansible/ansible-lint@main

      - name: Shellcheck
        run: shellcheck deploy.sh scripts/*.sh

      - name: Secret scan
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Шаг 3 — README с бейджем

```markdown
# DreamSeed

![CI](https://github.com/VitaliKuts/DreamSeed/actions/workflows/ci.yml/badge.svg)

Infrastructure-as-Code проект для автоматического развёртывания MODX-сайтов
на AWS / Hetzner. Terraform + Ansible, мониторинг Prometheus/Grafana,
бэкапы в Google Drive, алерты в Telegram.

## Архитектура

[mermaid-диаграмма]

## Quick start

\`\`\`bash
./deploy.sh prod -n        # AWS + Nginx
./deploy.sh dev-hetz -n    # Hetzner + Nginx
\`\`\`
```

### Шаг 4 — демонстрационный PR

Создать ветку, внести небольшое осмысленное изменение (например, добавить роль или правку в CLAUDE.md), открыть PR. Рекрутер увидит все проверки в действии.

---

## Альтернативы GitHub (если надо)

- **GitLab** — тот же CI (`.gitlab-ci.yml`), публичные проекты бесплатно
- **Gitea / Forgejo** — self-hosted на Hetzner-сервере (бонус: ещё один пункт в портфолио — «хостю свой git с CI»)
- **Bitbucket** — если Atlassian-экосистема

Идея везде одна: публичный репо + автолинтеры на каждый commit.

---

## Ответ на собеседовании

> «Инфраструктурный код лежит на GitHub с CI-пайплайном — на каждый PR запускается tflint, ansible-lint, tfsec, shellcheck и gitleaks. У заказчика workflow простой: один разработчик через SFTP заливает MODX-файлы на preprod. IaC к этому workflow отношения не имеет — это моя зона ответственности, она живёт отдельно и версионируется как положено.»

Это правильный ответ: показывает, что вы разделяете application deploy и infrastructure deploy, понимаете зоны ответственности.

---

## Чеклист на завтра

- [ ] Прогнать gitleaks локально
- [ ] Проверить `.gitignore` — нет ли утечек
- [ ] Создать публичный репо на GitHub
- [ ] `git init` + `git push`
- [ ] Добавить `.github/workflows/ci.yml`
- [ ] Переписать README (с бейджем + mermaid-диаграммой)
- [ ] Дождаться первого зелёного CI
- [ ] Создать демонстрационный PR
- [ ] Добавить ссылку на репо в резюме / LinkedIn
