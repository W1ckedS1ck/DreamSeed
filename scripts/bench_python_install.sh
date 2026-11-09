#!/usr/bin/env bash
# Benchmark pip vs uv for hash-pinned requirement files.
# Usage: scripts/bench_python_install.sh [--runs N] [--python X.Y] [file ...]
# Defaults: --runs 3 --python 3.14 ci/requirements.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

RUNS=3
PYTHON_VERSION="3.14"
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --python)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        -h | --help)
            sed -n '2,4p' "$0"
            exit 0
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

(( ${#FILES[@]} )) || FILES=("ci/requirements.txt")

command -v uv >/dev/null 2>&1 || {
    echo "uv is required (https://docs.astral.sh/uv/)" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

now_ms() { python3 -c 'import time; print(int(time.monotonic() * 1000))'; }

median() {
    printf '%s\n' "$@" | sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0) { print 0; exit }
            if (NR % 2) { print a[(NR + 1) / 2] }
            else { print int((a[NR / 2] + a[NR / 2 + 1]) / 2) }
        }'
}

format_speedup() {
    awk -v pip_ms="$1" -v uv_ms="$2" 'BEGIN {
        if (uv_ms <= 0) { print "n/a"; exit }
        printf "%.1fx", pip_ms / uv_ms
    }'
}

# run_case <pip|uv> <cold|warm> <requirements> -> median install time in ms
run_case() {
    local tool="$1" cache="$2" req="$3"
    local i start end ms venv
    local -a samples cmd

    for ((i = 1; i <= RUNS; i++)); do
        venv="$WORK/venv-${tool}-${cache}-${i}"
        rm -rf "$venv"
        if [[ "$tool" == "pip" ]]; then
            # --seed installs pip into the venv (not part of the measurement).
            uv venv --quiet --python "$PYTHON_VERSION" --seed "$venv"
            cmd=("$venv/bin/python" -m pip install --quiet --require-hashes -r "$req")
            [[ "$cache" == "cold" ]] && cmd+=(--no-cache-dir)
        else
            uv venv --quiet --python "$PYTHON_VERSION" "$venv"
            cmd=(uv pip install --quiet --python "$venv/bin/python" --require-hashes -r "$req")
            [[ "$cache" == "cold" ]] && cmd+=(--no-cache)
        fi

        if [[ "$cache" == "warm" && "$i" -eq 1 ]]; then
            # Prime the shared cache; this run is not counted.
            "${cmd[@]}" >/dev/null 2>&1 || true
        fi

        start="$(now_ms)"
        "${cmd[@]}" >/dev/null
        end="$(now_ms)"
        ms=$((end - start))
        samples+=("$ms")
    done

    median "${samples[@]}"
}

echo
echo "Python $PYTHON_VERSION · $RUNS runs · median install time (cold = no warm cache)"
echo
echo "| requirements | cache | pip | uv | speedup |"
echo "|---|---|---:|---:|---:|"

for req in "${FILES[@]}"; do
    [[ -f "$req" ]] || {
        echo "missing requirements file: $req" >&2
        exit 1
    }
    for cache in cold warm; do
        pip_ms="$(run_case pip "$cache" "$req")"
        uv_ms="$(run_case uv "$cache" "$req")"
        printf '| %s | %s | %s ms | %s ms | %s |\n' \
            "$req" "$cache" "$pip_ms" "$uv_ms" "$(format_speedup "$pip_ms" "$uv_ms")"
    done
done
echo
