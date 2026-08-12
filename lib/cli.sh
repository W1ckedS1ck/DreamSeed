# CLI argument parsing and target resolution for deploy.sh
# shellcheck shell=bash
# Sourced by deploy.sh — do not execute directly.

usage() {
    cat << 'EOF'
DreamSeed Deploy Script  v2.0.0

Usage: deploy.sh TARGET -n|-a [OPTIONS]

TARGETS:
  prod               AWS        dreamseed.online
  dev-aws            AWS        aws.vitalikuts.online
  dev-hetz           Hetzner    hetz.vitalikuts.online
  prod-hetz          Hetzner    dreamseed.online

WEB SERVER (required):
  -n                 Nginx
  -a                 Apache

OPTIONS:
  -i IP              Skip Terraform, use existing server
  -x, --destroy      Destroy resources
  -p, --parallel     Parallel playbook execution (3 phases)
  -d, --dry-run      Preview only
  -c, --check        Validate config & syntax only (no deploy)
  --no-dns           Skip Cloudflare DNS update
  -h                 Show this help
   --logs [tf]        Tail latest deploy/terraform log
   --lint             Run all linters locally (no deploy)
EOF
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 1; }

    if [[ "$1" == "--logs" ]]; then
        local prefix="deploy"
        [[ "${2:-}" == "tf" || "${2:-}" == "terraform" ]] && prefix="terraform"
        local latest; latest=$(ls -t "$LOG_DIR/${prefix}_"*.log 2>/dev/null | head -1)
        [[ -z "$latest" ]] && { echo "No ${prefix} logs found"; exit 1; }
        tail -f "$latest"; exit 0
    fi

    if [[ "$1" == "--lint" ]]; then
        run_lint && exit 0
        echo "  ✗ Some linters reported issues (see above)"
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            prod|dev-aws|dev-hetz|prod-hetz) TARGET="$1"; shift ;;
            -n) WEB_SERVER="nginx"; shift ;;
            -a) WEB_SERVER="apache"; shift ;;
            -i|--ip)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    echo "Error: -i requires an IP address argument"; usage; exit 1
                fi
                EXISTING_IP="$2"; SKIP_TERRAFORM=true; shift 2 ;;
            -x|--destroy) DESTROY_MODE=true; shift ;;
            -p|--parallel) PARALLEL_MODE=true; shift ;;
            -d|--dry-run) DRY_RUN=true; shift ;;
            -c|--check) CHECK_MODE=true; shift ;;
            --no-dns) SKIP_DNS=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "$TARGET" ]]; then echo "Error: target required"; usage; exit 1; fi
    if [[ -z "$WEB_SERVER" && "$DESTROY_MODE" == "false" ]]; then
        echo "Error: web server required (-n/-a)"; usage; exit 1
    fi
}

resolve_target() {
    ENV_FILE="$SCRIPT_DIR/secrets/.env"
    case "$TARGET" in
        prod)    TF_PROVIDER="aws";    DEPLOY_DOMAIN="dreamseed.online";       TF_WORKSPACE="prod";    TARGET_PREFIX="PROD"
                 SSH_ATTEMPTS=40; SSH_INTERVAL=10 ;;
        dev-aws) TF_PROVIDER="aws";    DEPLOY_DOMAIN="aws.vitalikuts.online";  TF_WORKSPACE="dev-aws"; TARGET_PREFIX="DEV_AWS"
                 SSH_ATTEMPTS=40; SSH_INTERVAL=10 ;;
        dev-hetz)  TF_PROVIDER="hetzner"; DEPLOY_DOMAIN="hetz.vitalikuts.online"; TF_WORKSPACE="dev-hetz";  TARGET_PREFIX="DEV_HETZ"
                   SSH_ATTEMPTS=90; SSH_INTERVAL=2 ;;
        prod-hetz) TF_PROVIDER="hetzner"; DEPLOY_DOMAIN="dreamseed.online";      TF_WORKSPACE="prod-hetz"; TARGET_PREFIX="PROD_HETZ"
                   SSH_ATTEMPTS=90; SSH_INTERVAL=2 ;;
        *) echo "Error: unknown target '$TARGET'. Valid: prod, dev-aws, dev-hetz, prod-hetz"; exit 1 ;;
    esac
    TF_DIR="$SCRIPT_DIR/terraform/$TF_PROVIDER"
}

run_lint() {
    bash "$SCRIPT_DIR/scripts/lint.sh" --fast
    local rc=$?
    if [[ "$TTY" == "false" ]]; then
        if [[ $rc -eq 0 ]]; then echo "::notice title=Lint::All linters passed"; fi
    fi
    return $rc
}
