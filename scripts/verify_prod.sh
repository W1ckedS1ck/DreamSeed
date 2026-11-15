#!/bin/bash
# verify_prod.sh — one-command production verification, run from the operator's machine.
#
# WHY THIS EXISTS
#   audit_deep.sh answers "is the server healthy?" from inside the box, but it cannot see
#   what a visitor sees (Cloudflare edge, TLS chain, DNS, the served bytes) and knows
#   nothing about files edited in web_root by hand. check_services.sh runs on the server
#   too. This script is the outside-in half: public endpoints, www edit hygiene, repo
#   drift — then it runs audit_deep.sh for the inside-out half and folds it into one
#   PASS/WARN/FAIL report.
#
# READ-ONLY
#   Nothing here writes: no restart, no chown, no cache purge, no deploy. Every fix it
#   suggests is printed for a human to run.
#
# USAGE
#   ./scripts/verify_prod.sh                 # full: outside-in + www edits + drift + audit
#   ./scripts/verify_prod.sh --fast          # skip the remote audit (2-3 s instead of ~10)
#   ./scripts/verify_prod.sh --www-only      # only the www edit / drift section
#   ./scripts/verify_prod.sh --since "3 hours ago"
#   ./scripts/verify_prod.sh --host my-alias --domain example.com
#
# EXIT CODE
#   Number of failed checks (0 = clean), warnings do not fail the run. Same convention as
#   audit_deep.sh, so it can be wired into CI or a cron later without reinterpretation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${DREAMSEED_HOST:-dream}"
DOMAIN="${DREAMSEED_DOMAIN:-}"
SINCE="24 hours ago"
RUN_AUDIT=1
WWW_ONLY=0
COLOR=1

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2 ;;
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --since) SINCE="${2:-}"; shift 2 ;;
        --fast) RUN_AUDIT=0; shift ;;
        --www-only) WWW_ONLY=1; RUN_AUDIT=0; shift ;;
        --no-color) COLOR=0; shift ;;
        -h | --help) usage ;;
        *)
            echo "unknown argument: $1 (try --help)" >&2
            exit 2
            ;;
    esac
done

# Domain: a flag/env wins. ansible/group_vars/all.yml is a Jinja template
# ({{ lookup('env','DEPLOY_DOMAIN') }}), so the apex is a constant here — prod is
# dreamseed.online (lib/cli.sh maps the prod target to it), dev targets differ.
DOMAIN="${DOMAIN:-dreamseed.online}"

WEB_ROOT="/var/www/html"
SCRIPTS_REMOTE="/home/ubuntu/Scripts"

if [ "$COLOR" -eq 1 ] && [ -t 1 ]; then
    G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; C=$'\033[0;36m'; D=$'\033[2m'; N=$'\033[0m'
else
    G=''; Y=''; R=''; C=''; D=''; N=''
fi

fails=0
warns=0
ok() {
    printf '  %s✓%s %s\n' "$G" "$N" "$1"
}
warn() {
    printf '  %s⚠%s %s\n' "$Y" "$N" "$1"
    warns=$((warns + 1))
}
fail() {
    printf '  %s✗%s %s\n' "$R" "$N" "$1"
    fails=$((fails + 1))
}
info() {
    printf '  %s·%s %s\n' "$D" "$N" "$1"
}
section() {
    printf '\n%s▶ %s%s\n' "$C" "$1" "$N"
}

ssh_prod() {
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@"
}

local_md5() {
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    else
        md5sum "$1" | cut -d' ' -f1
    fi
}

stdin_md5() {
    if command -v md5 >/dev/null 2>&1; then
        md5 -q
    else
        md5sum | cut -d' ' -f1
    fi
}

http() {
    # http <path> <extra curl args...> — prints "code time size body"
    local path="$1"
    shift
    curl -sk -m 20 -o /tmp/verify_prod_body.$$ -w '%{http_code} %{time_total} %{size_download}' \
        "$@" "https://$DOMAIN$path" 2>/dev/null
}

# ---------------------------------------------------------------- outside-in
outside_in() {
    section "Outside-in — https://$DOMAIN (через Cloudflare)"

    # The six endpoints Better Stack / HetrixTools probe. A wrong code here is a real
    # outage symptom, so these fail rather than warn.
    set -- "/:200" "/manager/:200" "/grafana:302" "/bot-health:200" "/catalog/bamboo:200" "/personal-account/registration:200"
    local e path want code time size
    for e in "$@"; do
        path="${e%:*}"
        want="${e##*:}"
        read -r code time size <<<"$(http "$path")"
        if [ "$code" = "$want" ]; then
            ok "$path → $code (${time}s)"
        else
            fail "$path → $code, ожидали $want"
        fi
        rm -f /tmp/verify_prod_body.$$
    done

    # Health endpoint body: 200 alone is not proof that the bot is alive.
    if [ "$(curl -sk -m 10 "https://$DOMAIN/bot-health" 2>/dev/null)" = "OK" ]; then
        ok "/bot-health тело = OK"
    else
        fail "/bot-health отдаёт не OK"
    fi

    # Keyword + headers are checked on captured strings, not on a pipe: `grep -q` exits
    # on the first match, curl would then die with SIGPIPE and `set -o pipefail` would
    # turn a healthy page into a failure.
    local home
    home="$(curl -sk -m 20 "https://$DOMAIN/" 2>/dev/null)"
    if grep -qF "Garden of Dreamers" <<<"$home"; then
        ok "главная содержит ключевое слово монитора"
    else
        fail "на главной нет 'Garden of Dreamers' (монитор Better Stack покраснеет)"
    fi

    # www must 301 to the apex, never 522/404 (Cloudflare Full(strict) needs the SAN).
    local www_code www_loc
    www_code="$(curl -sk -m 20 -o /dev/null -w '%{http_code}' "https://www.$DOMAIN/" 2>/dev/null)"
    www_loc="$(curl -sk -m 20 -o /dev/null -w '%{redirect_url}' "https://www.$DOMAIN/" 2>/dev/null)"
    if [ "$www_code" = "301" ] && [ "$www_loc" = "https://$DOMAIN/" ]; then
        ok "www.$DOMAIN → 301 https://$DOMAIN/"
    else
        fail "www.$DOMAIN → $www_code $www_loc (ожидали 301 на apex)"
    fi

    # Certificate: expiry and SAN. The apex is served by Cloudflare, so read the origin
    # certificate through its IP as well when we can resolve it.
    local expiry days
    expiry="$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -n "$expiry" ]; then
        local end_epoch now_epoch
        end_epoch="$(date -j -f '%b %d %T %Y %Z' "$expiry" +%s 2>/dev/null || date -d "$expiry" +%s 2>/dev/null)"
        now_epoch="$(date +%s)"
        if [ -n "$end_epoch" ]; then
            days=$(((end_epoch - now_epoch) / 86400))
            if [ "$days" -lt 14 ]; then
                fail "TLS истекает через $days дн. — продление не работает"
            elif [ "$days" -lt 30 ]; then
                warn "TLS истекает через $days дн."
            else
                ok "TLS действителен $days дн."
            fi
        fi
    else
        warn "не удалось прочитать TLS-сертификат"
    fi

    local san
    san="$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null |
        openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -c "$DOMAIN")"
    if [ "${san:-0}" -ge 1 ]; then
        ok "SAN содержит $DOMAIN"
    else
        warn "в SAN нет $DOMAIN (проверь сертификат)"
    fi

    # DNS: both names must land on the same edge, otherwise www caching/certs diverge.
    local a_apex a_www
    a_apex="$(dig +short "$DOMAIN" A 2>/dev/null | sort | tr '\n' ' ')"
    a_www="$(dig +short "www.$DOMAIN" 2>/dev/null | sort | tr '\n' ' ')"
    if [ -n "$a_apex" ] && [ -n "$a_www" ]; then
        if [ "$a_apex" = "$a_www" ]; then
            ok "DNS: apex и www на одном крае ($(echo "$a_apex" | wc -w | tr -d ' ') IP)"
        else
            warn "DNS: apex и www различаются (apex ${a_apex:-—} / www ${a_www:-—})"
        fi
    else
        fail "DNS: один из хостов не резолвится"
    fi

    # Edge IPs are identical for every proxied record, so the check above cannot
    # catch a stale origin (exactly how www pointed at a dead host until
    # 2026-11-12). Compare the A-record *content* when a Cloudflare token is
    # available; stay read-only and skip cleanly when it is not.
    if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
        local zone zone_id apex_origin www_origin
        zone="$(dig +noall +answer SOA "$DOMAIN" 2>/dev/null | awk 'NR==1 {sub(/\.$/, "", $1); print $1}')"
        zone_id=""
        if [ -n "$zone" ]; then
            zone_id="$(curl -fsS -m 10 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                -G --data-urlencode "name=$zone" "https://api.cloudflare.com/client/v4/zones" 2>/dev/null |
                python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "", end="")' 2>/dev/null || true)"
        fi

        cf_a() { # fqdn -> newline-separated origin IPs; non-zero on API failure
            local body
            body="$(curl -fsS -m 10 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                -G --data-urlencode "type=A" --data-urlencode "name=$1" \
                "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" 2>/dev/null)" || return 1
            printf '%s' "$body" |
                python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(sorted(r["content"] for r in d.get("result",[]))), end="")' 2>/dev/null || return 1
        }

        if [ -z "$zone_id" ]; then
            warn "DNS origin: не удалось получить zone id (проверь CLOUDFLARE_API_TOKEN)"
        elif ! apex_origin="$(cf_a "$DOMAIN")"; then
            warn "DNS origin: Cloudflare API не отдал A-записи $DOMAIN"
        elif ! www_origin="$(cf_a "www.$DOMAIN")"; then
            warn "DNS origin: Cloudflare API не отдал A-записи www.$DOMAIN"
        elif [ -z "$www_origin" ]; then
            info "DNS origin: A-записи www.$DOMAIN нет (алиас не настроен)"
        elif [ "$apex_origin" = "$www_origin" ]; then
            ok "DNS origin: apex и www указывают на один origin ($(printf '%s' "$apex_origin" | tr '\n' ' '))"
        else
            fail "DNS origin: apex и www расходятся (apex ${apex_origin:-—} / www ${www_origin:-—})"
        fi
    else
        info "DNS origin: CLOUDFLARE_API_TOKEN не задан — проверка origin пропущена"
    fi

    # Edge headers: cheap regression guard for the CSP/HSTS work in PR #301.
    local headers missing=""
    headers="$(curl -sk -m 20 -D - -o /dev/null "https://$DOMAIN/" 2>/dev/null)"
    for h in strict-transport-security content-security-policy x-content-type-options; do
        grep -qi "^$h:" <<<"$headers" || missing="$missing $h"
    done
    if [ -z "$missing" ]; then
        ok "security-заголовки на месте (HSTS, CSP, nosniff)"
    else
        warn "не хватает заголовков:$missing"
    fi
}

# ---------------------------------------------------------------- www edits
# The section that matters while hand-editing web_root: who owns the file, whether the
# site can still write next to it, and whether clients will actually see the new bytes.
www_edits() {
    section "Правки в $WEB_ROOT за '$SINCE' (без кэшей)"

    local listing
    listing="$(ssh_prod "sudo find $WEB_ROOT -xdev -type f -newermt '$SINCE' \
        ! -path '*/core/cache/*' ! -path '*/core/backup/*' ! -path '*/tiles/*' \
        -printf '%s|%u:%g|%m|%p\n' 2>/dev/null" </dev/null)" || {
        fail "ssh $HOST недоступен"
        return
    }

    if [ -z "$listing" ]; then
        info "изменённых файлов нет — проверять нечего"
        return
    fi

    local count size owner mode path bad_owner=0 world_w=0
    count="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
    info "изменено файлов: $count"

    local html
    html="$(curl -sk -m 20 "https://$DOMAIN/" 2>/dev/null)"

    local php_files="" js_css=""
    while IFS='|' read -r size owner mode path; do
        [ -n "$path" ] || continue
        printf '  %s·%s %-58s %8sB %s %s\n' "$D" "$N" "${path#"$WEB_ROOT"/}" "$size" "$owner" "$mode"
        case "$owner" in
            www-data:www-data | root:www-data) ;;
            *)
                bad_owner=$((bad_owner + 1))
                ;;
        esac
        # Other-bit write in the octal mode (664 -> 0, 666 -> 1).
        if [ $((8#$mode & 8#002)) -ne 0 ]; then
            world_w=$((world_w + 1))
        fi
        case "$path" in
            *.php) php_files="$php_files $path" ;;
            *.js | *.css) js_css="$js_css ${path#"$WEB_ROOT"/}" ;;
        esac
    done <<<"$listing"

    if [ "$bad_owner" -eq 0 ]; then
        ok "владельцы файлов в порядке (www-data или root:www-data)"
    else
        fail "$bad_owner файл(ов) не под www-data — MODX не сможет писать рядом: sudo chown www-data:www-data <файл>"
    fi
    [ "$world_w" -eq 0 ] && ok "нет world-writable файлов" || fail "$world_w world-writable файл(ов)"

    # PHP syntax before traffic finds it.
    if [ -n "$php_files" ]; then
        local lint_out
        lint_out="$(ssh_prod "for f in $php_files; do sudo -u www-data php -l \"\$f\" 2>&1; done" </dev/null)"
        if grep -q "Parse error" <<<"$lint_out"; then
            fail "php -l нашёл синтаксическую ошибку: $(echo "$lint_out" | grep -m1 -i 'error')"
        else
            ok "php -l: ошибок нет ($(echo "$php_files" | wc -w | tr -d ' ') файл(ов))"
        fi
    fi

    # Static assets: `?v=` must be bumped and the edge must serve exactly these bytes.
    # Both are the same class of bug — the file is new, the visitor gets the old one.
    local asset base served disk disk_sums=""
    if [ -n "$js_css" ]; then
        disk_sums="$(ssh_prod "sudo md5sum $(echo $js_css | sed "s#^#$WEB_ROOT/#g") 2>/dev/null" </dev/null)"
    fi
    for asset in $js_css; do
        base="$(basename "$asset")"
        # Static assets are immutable for 30 days at the edge: without a version the
        # old copy lives on in every browser that already has it.
        if grep -qF "$base?v=" <<<"$html"; then
            ok "$base подключён с версией (?v=…)"
        elif grep -qF "$base" <<<"$html"; then
            warn "$base подключён БЕЗ ?v= — верни кэш-версию, иначе 30-дневный immutable кэш отдаст старое"
        else
            info "$base не найден на главной (проверь страницу, где он используется)"
        fi
        served="$(curl -sk -m 20 "https://$DOMAIN/$asset" 2>/dev/null | stdin_md5)"
        disk="$(printf '%s\n' "$disk_sums" | awk -v n="$WEB_ROOT/$asset" '$2 == n {print $1; exit}')"
        if [ -n "$served" ] && [ -n "$disk" ]; then
            if [ "$served" = "$disk" ]; then
                ok "$base отдаётся наружу байт-в-байт"
            else
                warn "$base наружу ≠ на диске (кэш края/браузера; подними ?v= или purge)"
            fi
        fi
    done
}

# ---------------------------------------------------------------- drift
drift() {
    section "Дрейф: репозиторий ↔ $SCRIPTS_REMOTE"

    # Only the files the backup role actually uploads: comparing the whole scripts/ dir
    # would flag every local-only tool (lint.sh, this script, ...) — noise, not drift.
    local upload_list
    upload_list="$(sed -n '/- name: Upload backup scripts/,/^- name: /p' \
        "$REPO_DIR/ansible-roles/backup/tasks/main.yml" 2>/dev/null |
        grep -E '^[[:space:]]+- [a-zA-Z0-9_.]+$' | sed -E 's/^[[:space:]]+- //' | head -20)"

    if [ -z "$upload_list" ]; then
        warn "не удалось прочитать upload-список из роли backup"
        return
    fi

    # One ssh round-trip for all of them: a per-file ssh call costs ~2 s each.
    local remote_sums
    remote_sums="$(ssh_prod "cd $SCRIPTS_REMOTE 2>/dev/null && md5sum $(echo $upload_list | tr ' ' ' ') 2>/dev/null" </dev/null)"

    local differing=0 missing=0 total=0 f remote_sum local_sum
    for f in $upload_list; do
        total=$((total + 1))
        [ -f "$REPO_DIR/scripts/$f" ] || continue
        remote_sum="$(printf '%s\n' "$remote_sums" | awk -v n="$f" '$2 == n {print $1; exit}')"
        if [ -z "$remote_sum" ]; then
            missing=$((missing + 1))
            printf '  %s·%s %-28s нет на сервере\n' "$D" "$N" "$f"
            continue
        fi
        local_sum="$(local_md5 "$REPO_DIR/scripts/$f")"
        if [ "$remote_sum" != "$local_sum" ]; then
            differing=$((differing + 1))
            printf '  %s·%s %-28s отличается (на сервере своя версия)\n' "$D" "$N" "$f"
        fi
    done

    if [ "$differing" -eq 0 ] && [ "$missing" -eq 0 ]; then
        ok "все $total задеплоенных скриптов совпадают с репозиторием"
    else
        [ "$differing" -gt 0 ] && warn "$differing из $total скриптов отличаются — обновит ближайший деплой (не ошибка, но знай)"
        [ "$missing" -gt 0 ] && warn "$missing скриптов из upload-списка нет на сервере"
    fi
}

# ---------------------------------------------------------------- server audit
server_audit() {
    section "Серверный аудит (audit_deep.sh)"

    local out rc
    out="$(ssh_prod "cd $SCRIPTS_REMOTE && sudo bash audit_deep.sh 2>&1; echo \"__EXIT__\$?\"" </dev/null)"
    rc="$(printf '%s' "$out" | sed -n 's/^__EXIT__//p')"
    out="$(printf '%s' "$out" | sed '/^__EXIT__/d')"

    # audit_deep prints ok/warn/fail lines; anything not ok is what a human must read.
    local ok_count
    ok_count="$(printf '%s' "$out" | grep -cE '^\s*(✓|✔)' || true)"
    if [ "${rc:-1}" -eq 0 ]; then
        ok "audit_deep.sh: $ok_count проверок, 0 fail (exit $rc)"
    else
        fail "audit_deep.sh: exit $rc"
        printf '%s\n' "$out" | grep -E '^\s*(✗|⚠|✘)' | head -10 | sed 's/^/     /'
    fi
}

printf '%s═══ verify_prod ═══%s  host=%s domain=%s\n' "$C" "$N" "$HOST" "$DOMAIN"

if ! ssh_prod "true" </dev/null 2>/dev/null; then
    fail "ssh $HOST недоступен — внешние проверки продолжатся, серверные нет"
    RUN_AUDIT=0
fi

[ "$WWW_ONLY" -eq 0 ] && outside_in
www_edits
[ "$WWW_ONLY" -eq 0 ] && drift
[ "$RUN_AUDIT" -eq 1 ] && server_audit

# tempfile cleanup (the body file is recreated per request)
rm -f /tmp/verify_prod_body.$$

printf '\n%s═══ ИТОГ ═══%s\n' "$C" "$N"
if [ "$fails" -eq 0 ] && [ "$warns" -eq 0 ]; then
    printf '  %s✓ всё чисто%s\n\n' "$G" "$N"
elif [ "$fails" -eq 0 ]; then
    printf '  %s⚠%s предупреждений: %s, ошибок нет\n\n' "$Y" "$N" "$warns"
else
    printf '  %s✗%s ошибок: %s, предупреждений: %s\n\n' "$R" "$N" "$fails" "$warns"
fi

exit "$fails"
