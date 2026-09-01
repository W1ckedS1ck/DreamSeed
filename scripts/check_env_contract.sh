#!/usr/bin/env bash
# Cross-parser .env contract check (zero deps: bash + python3).
#
# The same secrets flow through three independent parsers:
#   lib/env.sh (deploy controller) | scripts/common_functions.sh load_env
#   (server scripts) | scripts/env_loader.py (telegram bot)
# Run this BEFORE editing any of them — it asserts identical output for the
# shared contract fixtures and freezes the documented divergences (blocked
# vars / malformed lines / ENV: lib/env.sh fails loudly, server side skips).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/env"
HOME_STUB="/home/contract-test"

PASS=0
FAIL=0
PRESET=""

ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

dump_keys() { # keys... -> KEY=value lines, multi-line values escaped as \n
    local k v
    for k in $1; do
        if declare -p "$k" >/dev/null 2>&1; then
            v="${!k}"
            printf '%s=%s\n' "$k" "${v//$'\n'/\\n}"
        else
            printf '%s=<UNSET>\n' "$k"
        fi
    done
}

preset_vars() { # deterministic env for expansion fixtures
    export HOME="$HOME_STUB"
    if [[ "$PRESET" == "cycle" ]]; then
        export EC_CYCLE_A='$EC_CYCLE_A'
    fi
}

run_one() { # parser lib|server|py fixture keys -> dump on stdout, rc = parser rc
    local parser="$1" f="$2" keys="$3"
    case "$parser" in
        lib)
            (
                preset_vars
                # shellcheck disable=SC1090 # fixture-driven source path
                source "$ROOT/lib/env.sh"
                if ! parse_env_file "$f"; then exit 1; fi
                dump_keys "$keys"
            ) ;;
        server)
            (
                preset_vars
                # shellcheck disable=SC1090
                source "$ROOT/scripts/common_functions.sh"
                if ! load_env "$f"; then exit 1; fi
                dump_keys "$keys"
            ) ;;
        py)
            (
                preset_vars
                export EC_KEYS="$keys" EC_FILE="$f" EC_ROOT="$ROOT"
                python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ['EC_ROOT'], 'scripts'))
from env_loader import load_env
load_env(os.environ['EC_FILE'])
for k in os.environ['EC_KEYS'].split():
    print(f"{k}={os.environ.get(k, '<UNSET>').replace(chr(10), chr(92) + 'n')}")
PY
            ) ;;
        *)
            echo "Unknown parser: $parser" >&2
            exit 2
            ;;
    esac
}

# check_fixture <file> <keys> <mode eq|div_lib_fail|all_fail> [preset]
check_fixture() {
    local name="$1" keys="$2" mode="$3" preset="${4:-}"
    local f="$FIXTURES/$name"
    local d_lib="" d_srv="" d_py=""
    local rc_lib=0 rc_srv=0 rc_py=0

    PRESET="$preset"
    d_lib=$(run_one lib "$f" "$keys" 2>/dev/null) || rc_lib=$?
    d_srv=$(run_one server "$f" "$keys" 2>/dev/null) || rc_srv=$?
    d_py=$(run_one py "$f" "$keys" 2>/dev/null) || rc_py=$?
    PRESET=""

    case "$mode" in
        eq)
            if [[ $rc_lib -eq 0 && $rc_srv -eq 0 && $rc_py -eq 0 &&
                "$d_lib" == "$d_srv" && "$d_srv" == "$d_py" ]]; then
                ok "$name: 3/3 identical"
            else
                bad "$name: outputs diverge (rc lib=$rc_lib server=$rc_srv py=$rc_py)"
                diff <(printf '%s' "$d_lib") <(printf '%s' "$d_srv") | sed 's/^/      /' || true
                diff <(printf '%s' "$d_srv") <(printf '%s' "$d_py") | sed 's/^/      /' || true
            fi
            ;;
        div_lib_fail)
            if [[ $rc_lib -ne 0 && $rc_srv -eq 0 && $rc_py -eq 0 && "$d_srv" == "$d_py" ]]; then
                ok "$name: lib fails loudly, server parsers agree"
            else
                bad "$name: unexpected (rc lib=$rc_lib server=$rc_srv py=$rc_py)"
            fi
            ;;
        all_fail)
            if [[ $rc_lib -ne 0 && $rc_srv -ne 0 && $rc_py -ne 0 ]]; then
                ok "$name: all 3 reject"
            else
                bad "$name: expected rejection everywhere (rc lib=$rc_lib server=$rc_srv py=$rc_py)"
            fi
            ;;
        *)
            bad "$name: unknown mode '$mode'"
            ;;
    esac
}

[[ -d "$FIXTURES" ]] || {
    echo "Fixtures directory not found: $FIXTURES" >&2
    exit 2
}

printf '%s\n' "  ▶ .env parser contract (lib/env.sh vs common_functions.sh vs env_loader.py)"

check_fixture "basic.env" \
    "EC_PLAIN EC_QUOTED EC_SINGLE EC_EXPORTED EC_COMMENT EC_TRAIL EC_HASH EC_EMPTY" eq
check_fixture "expansion.env" \
    "EC_HOME_REF EC_HOME_BRACED EC_FIRST EC_SECOND EC_THIRD EC_UNDEF_REF EC_LOWER_REF" eq
check_fixture "multiline.env" \
    "EC_MULTI_D EC_MULTI_S EC_MULTI_C EC_AFTER" eq
check_fixture "blocked.env" "PATH EC_SURVIVOR" div_lib_fail
check_fixture "malformed.env" "EC_SURVIVOR2" div_lib_fail
check_fixture "env_key.env" "ENV EC_SURVIVOR3" div_lib_fail
check_fixture "inject.env" "EC_BAD" all_fail
check_fixture "unterminated.env" "EC_OPEN" all_fail
check_fixture "cycle.env" "EC_CYCLE_A" all_fail cycle

printf '\n'
if [[ $FAIL -eq 0 ]]; then
    printf '  ✓ All %s contract checks passed\n' "$PASS"
    exit 0
fi
printf '  ✗ %s of %s checks FAILED\n' "$FAIL" "$((PASS + FAIL))"
exit 1
