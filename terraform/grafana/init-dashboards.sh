#!/bin/bash
# Download latest Grafana dashboard revisions for Terraform provisioning.
# Must run BEFORE `terraform plan` — JSON files are read during plan phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.dashboards"
mkdir -p "$CACHE_DIR"

DASHBOARDS="1860:node_exporter 7362:mysql 17452:nginx 763:redis 10229:victoria_metrics"

for pair in $DASHBOARDS; do
    gid="${pair%%:*}"
    name="${pair##*:}"
    out="$CACHE_DIR/$name.json"
    if [ -f "$out" ] && [ -s "$out" ]; then
        echo "  ✓ $name (cached)"
    else
        echo "  ↓ $name (downloading revision $gid)..."
        curl -sf "https://grafana.com/api/dashboards/$gid/revisions/latest/download" -o "$out"
        echo "  ✓ $name (downloaded)"
    fi
done
