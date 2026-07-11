## WebPageTest — Findings & фиксы

> Июль 2026. Всё, что не влезло в инфраструктурный код.

### Починили через код / сервер

| Фикс | Где |
|------|-----|
| TTFB 86 → 100 (A) | nginx + mailTest + tmpfs |
| favicon 404 → 200 | nginx `try_files` |
| mailTest 5 ошибок/стр | сниппет-заглушка в БД |
| tmpfs не монтировался | mount + fstab + `nofail` |
| Terraform state сломан | state rm + reimport на dev + prod |
| Cloudflare кеш не работал | ruleset починен, PHPSESSID bypass |

### Осталось разработчику (MODX шаблоны)

#### 1. CSS/JS дублируются ×4-8

**Причина**: `[[$head]]` и `[[$js]]` вызываются многократно в цепочке чанков.
Каждый CSS — 8 раз в HTML, каждый JS — 4 раза. Браузер берёт из кеша, но WPT штрафует.

**Фикс**: вынести CSS в `[[$css]]`, JS в `[[$js]]` — вызывать 1 раз в основном шаблоне.
`[[$head]]` оставить только для `<meta>`, `<title>`, шрифтов.

#### 2. 20 JS блокируют рендер

Кроме `email-decode.min.js` (см. ниже), все скрипты из `[[$js]]` можно грузить с `defer`.

**Фикс**: в `[[$js]]` добавить `defer` ко всем `<script>`. Если какой-то скрипт нужен до рендера (корзина в шапке) — оставить без `defer`.

#### 3. CLS 0.238 из-за 8 видео MP4

8.6 MB видео без `width`/`height`. При загрузке контент прыгает.

**Фикс**: добавить каждому `<video>`:

```html
<video width="640" height="360" style="aspect-ratio: 640/360" ...>
```

Или CSS-обёртку с `aspect-ratio: 16/9`.

#### 4. Google Fonts → CLS

Comfortaa грузится асинхронно, текст прыгает с sans-serif на Comfortaa.

**Фикс**: в ссылке на fonts.googleapis.com добавить `&display=swap`. В CSS указать `font-display: optional`.

#### 5. favicon2.png не сжат

`/theme/images/favicon2.png` (2.7 KB, можно до 1 KB).
Конвертнуть в `.webp` или прогнать через ImageOptim/optipng.

### Cloudflare Dashboard (не terraform)

#### Email Obfuscation

Текущий CF API токен не имеет прав `zone:settings:edit`.
Если хочешь через код — нужно расширить токен.

Пока руками:

- **Dev**: Cloudflare → vitalikuts.online → Speed → Optimization → Email Address Obfuscation → **Off**
- **Prod**: то же для dreamseed.online

После этого `email-decode.min.js` исчезнет.

#### Speculation Rules (на dev)

Включено на dev, выключено на prod. Разница:

- Dev: +2 балла WPT (Cache Static 92 vs 94)
- WPT штрафует из-за `no-store` на `/cdn-cgi/speculation`

Решать: отключить для совпадения с prod или оставить для реальных юзеров.

### Прочее

- `cdn-cgi/scripts/.../email-decode.min.js` — только если Email Obfuscation ON
- WPT Performance 54-55 — это вес 10.4 MB (83% = 8 видео). Не TTFB
- После фиксов фронтендера Performance вырастет до ~75-85
