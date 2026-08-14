#!/bin/bash
# Shared functions for DreamSeed scripts. Source this file, do not execute directly.

# shellcheck disable=SC2034  # color vars are consumed by sourcing scripts
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[0;31m'
  CYAN=$'\033[0;36m'
  NC=$'\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; NC=''
fi

# Backup rotation defaults (can be overridden via environment)
BACKUP_PROJECT_KEEP="${BACKUP_PROJECT_KEEP:-5}"
BACKUP_DB_KEEP="${BACKUP_DB_KEEP:-15}"

load_env() {
    local env_file="$1"
    [[ ! -f "$env_file" ]] && { echo "Error: file $env_file not found!" >&2; exit 1; }
    # Same .env contract as lib/env.sh parse_env_file (deploy.sh): KEY=value,
    # optional "quotes", inline comments after space+#, multi-line quoted
    # values, $HOME / $UPPERCASE_VAR expansion (double-quoted/unquoted only).
    # No source/eval — no RCE.
    local blocked_vars='^(PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|SHELL|SHELLOPTS|BASHOPTS|BASH_FUNC_.*)$'
    local key="" value="" quote="" no_expand=""
    while IFS= read -r line; do
        line="${line#export }"
        if [[ -n "$quote" ]]; then
            # Multi-line quoted value — accumulate until the closing quote
            if [[ "$line" == *"$quote" ]]; then
                value+=$'\n'"${line%"$quote"}"
                export "$key=$value"; key=""; value=""; quote=""
            else
                value+=$'\n'"$line"
            fi
            continue
        fi
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ "$key" =~ $blocked_vars ]] && { key=""; continue; }
        no_expand=""
        if [[ "$value" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
            value="${BASH_REMATCH[1]}"; no_expand="1"
        elif [[ "$value" =~ ^\"(.*)$ || "$value" =~ ^\'(.*)$ ]]; then
            quote="${value:0:1}"; value="${value:1}"; continue
        else
            value="${value%%[[:space:]]#*}"                    # strip inline comment
            value="${value%"${value##*[![:space:]]}"}"         # trim trailing whitespace
        fi
        if [[ -z "$no_expand" ]]; then
            while [[ "$value" =~ \$\{?([A-Z_][A-Z0-9_]*)\}? ]]; do
                local v="${BASH_REMATCH[1]}"
                value="${value//\$\{$v\}/${!v:-}}"
                value="${value//\$$v/${!v:-}}"
            done
        fi
        if [[ "$value" == *'$('* || "$value" == *'`'* ]]; then
            echo "Error: command substitution in $key" >&2; exit 1
        fi
        export "$key=$value"; key=""; value=""
    done < "$env_file"
    OWNER="${OWNER:-}"
}

# Detect environment suffix for backup paths.
# Prod → ""  (backs up to DreamSeed/backups/project/ and db/)
# Dev  → "-dev" (backs up to DreamSeed/backups/project-dev/ and db-dev/)
#
# DESIGN NOTE: Dev uploads to dev-specific paths, but ALL restore logic
# (deploy restore role, RESTORE_ALL.sh --auto-latest, interactive mode)
# pulls from prod paths only. Dev is an ephemeral copy of prod — it has
# no independent backup pipeline. Dev cloud backups exist as a safety
# net only; they are never consumed by any restore flow.
detect_env() {
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        local env_val
        env_val=$(grep '^ENV=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | sed 's/^ENV=//; s/^"//; s/"$//' || true)
        if [[ "$env_val" == prod* ]]; then
            echo ""
        elif [[ -n "$env_val" ]]; then
            echo "-${env_val}"
        else
            echo "-dev"
        fi
    else
        local h
        h=$(hostname)
        case "$h" in
            *-prod|*prod-*) echo "" ;;
            *) echo "-dev" ;;
        esac
    fi
}

format_env_display() {
    local env="$1"
    if [ -z "$env" ]; then
        echo "prod"
    else
        echo "$env"
    fi
}

format_env_escaped() {
    local env="$1"
    if [ -z "$env" ]; then
        echo "<b>PROD</b>"
    else
        echo "<b><i>$env</i></b>"
    fi
}

format_name() {
    basename "$1" | sed 's/DreamSeed_//; s/db_modx_db_//; s/^db_//; s/.tar.gz//; s/.sql.gz//; s/_/ /'
}

send_tg() {
    local text="$1"
    local parse_mode="${2:-HTML}"
    # Keep the token out of argv (ps aux) — curl reads the URL from a
    # 0600 temp config file instead of a command-line argument.
    local tg_cfg tg_url tg_resp err
    tg_cfg=$(mktemp) || return 0
    chmod 600 "$tg_cfg"
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" > "$tg_cfg"
    local data=(
        --data-urlencode "chat_id=$TG_CHAT_ID"
        --data-urlencode "text=$text"
        --data-urlencode "parse_mode=$parse_mode"
    )
    [[ -n "${TG_THREAD_ID:-}" ]] && data+=(--data-urlencode "message_thread_id=$TG_THREAD_ID")
    tg_resp=$(curl -s -m 10 -X POST --config "$tg_cfg" "${data[@]}" 2>/dev/null) || true
    rm -f "$tg_cfg"
    if ! echo "$tg_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        err=$(echo "$tg_resp" | jq -r '.description // "unknown"' 2>/dev/null || echo "unknown")
        echo "WARNING: Telegram send failed: $err" >&2
    fi
}

ping_heartbeat() {
    local key="${1:-}"
    [[ -z "$key" ]] && return 0
    if curl -fsS -m 10 --retry 3 -o /dev/null "https://uptime.betterstack.com/api/v1/heartbeat/$key"; then
        return 0
    else
        echo "WARNING: Better Stack heartbeat failed (previous heartbeat will expire): $key" >&2
        return 1
    fi
}

rclone_retry() {
    local max_attempts="${RCLONE_RETRIES:-3}"
    local attempt=1 rc timeout_secs="${RCLONE_CMD_TIMEOUT:-600}"
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            local delay=$((attempt * 5))
            echo "[rclone_retry] attempt $attempt/$max_attempts — waiting ${delay}s" >&2
            sleep "$delay"
        fi
        timeout "$timeout_secs" rclone "$@" --timeout=30s --retries 1 --retries-sleep 1s && return 0
        rc=$?
        attempt=$((attempt + 1))
    done
    return "$rc"
}

prune_cloud_backups() {
    local subdir="$1" max="$2"
    local all
    all=$(rclone_retry lsf "$RCLONE_REMOTE:$REMOTE_BASE/${subdir}${ENV_SUFFIX}/" --files-only 2>/dev/null | sort -r) || return 1
    local count
    count=$(printf '%s\n' "$all" | grep -c '[^[:space:]]' || true)
    if [ "$count" -gt "$max" ]; then
        printf '%s\n' "$all" | tail -n +$((max + 1)) | while read -r file; do
            [ -n "$file" ] && rclone_retry delete "$RCLONE_REMOTE:$REMOTE_BASE/${subdir}${ENV_SUFFIX}/$file" || true
        done
    fi
}

rotate_files() {
    local pattern="$1"
    local keep="$2"
    local dir glob
    dir=$(dirname "$pattern")
    glob=$(basename "$pattern")
    mapfile -t files < <(find "$dir" -maxdepth 1 -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ "${#files[@]}" -gt "$keep" ]; then
        for ((i=keep; i<${#files[@]}; i++)); do
            rm -f "${files[i]}"
        done
    fi
}

# List files matching a glob in a dir, newest first (paths only).
# Callers pick with `head -N` (latest, or a report list).
# `|| true` keeps callers safe under `set -euo pipefail` when the dir is
# missing (find exits 1) — "no backups yet" must not abort the calling script.
list_backups() {
    find "$1" -maxdepth 1 -name "$2" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- || true
}

export_metric() {
    local payload="$1"
    echo "$payload" | timeout 10 curl -s --data-binary @- "http://127.0.0.1:8428/api/v1/import/prometheus" > /dev/null 2>&1 || true
}
