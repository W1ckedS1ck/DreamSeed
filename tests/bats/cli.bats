#!/usr/bin/env bats
# Unit tests for lib/cli.sh argument parsing and target resolution.
# parse_args/resolve_target call exit on bad input, so every case runs inside
# bats' `run` subshell — the test process is never terminated.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT_DIR="$REPO_ROOT"
    LOG_DIR="$BATS_TEST_TMPDIR/logs"
    mkdir -p "$LOG_DIR"
    TTY=false

    TARGET=""
    WEB_SERVER=""
    TF_PROVIDER=""
    TF_WORKSPACE=""
    TARGET_PREFIX=""
    DEPLOY_DOMAIN=""
    TF_DIR=""
    EXISTING_IP=""
    SKIP_TERRAFORM=false
    DESTROY_MODE=false
    PARALLEL_MODE=false
    DRY_RUN=false
    CHECK_MODE=false
    SKIP_DNS=false

    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/cli.sh"
}

parse_and_report() {
    parse_args "$@"
    printf 'target=%s web=%s destroy=%s parallel=%s dry=%s check=%s dns=%s ip=%s skip_tf=%s' \
        "$TARGET" "$WEB_SERVER" "$DESTROY_MODE" "$PARALLEL_MODE" "$DRY_RUN" \
        "$CHECK_MODE" "$SKIP_DNS" "$EXISTING_IP" "$SKIP_TERRAFORM"
}

resolve_and_report() {
    TARGET="$1"
    resolve_target
    printf '%s|%s|%s|%s' "$TF_PROVIDER" "$DEPLOY_DOMAIN" "$TF_WORKSPACE" "$TARGET_PREFIX"
}

@test "nginx deploy target is parsed" {
    run parse_and_report dev-hetz -n
    [ "$status" -eq 0 ]
    [ "$output" = "target=dev-hetz web=nginx destroy=false parallel=false dry=false check=false dns=false ip= skip_tf=false" ]
}

@test "apache + parallel + no-dns flags are parsed" {
    run parse_and_report prod-hetz -a -p --no-dns
    [ "$status" -eq 0 ]
    [ "$output" = "target=prod-hetz web=apache destroy=false parallel=true dry=false check=false dns=true ip= skip_tf=false" ]
}

@test "existing IP implies skip-terraform" {
    run parse_and_report dev-aws -n -i 203.0.113.7
    [ "$status" -eq 0 ]
    [ "$output" = "target=dev-aws web=nginx destroy=false parallel=false dry=false check=false dns=false ip=203.0.113.7 skip_tf=true" ]
}

@test "destroy does not require a web server" {
    run parse_and_report dev-hetz -x
    [ "$status" -eq 0 ]
    [ "$output" = "target=dev-hetz web= destroy=true parallel=false dry=false check=false dns=false ip= skip_tf=false" ]
}

@test "missing arguments print usage and fail" {
    run parse_and_report
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: deploy.sh"* ]]
}

@test "unknown option fails" {
    run parse_and_report dev-hetz -n --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option: --nope"* ]]
}

@test "missing target fails" {
    run parse_and_report -n
    [ "$status" -ne 0 ]
    [[ "$output" == *"target required"* ]]
}

@test "deploy without -n/-a fails" {
    run parse_and_report dev-hetz
    [ "$status" -ne 0 ]
    [[ "$output" == *"web server required"* ]]
}

@test "-i without a value fails" {
    run parse_and_report dev-hetz -n -i
    [ "$status" -ne 0 ]
    [[ "$output" == *"-i requires an IP address"* ]]
}

@test "resolve_target maps every provider-agnostic target" {
    run resolve_and_report dev-hetz
    [ "$status" -eq 0 ]
    [ "$output" = "hetzner|hetz.vitalikuts.online|dev-hetz|DEV_HETZ" ]

    run resolve_and_report prod-hetz
    [ "$output" = "hetzner|dreamseed.online|prod-hetz|PROD_HETZ" ]

    run resolve_and_report dev-aws
    [ "$output" = "aws|aws.vitalikuts.online|dev-aws|DEV_AWS" ]

    run resolve_and_report prod
    [ "$output" = "aws|dreamseed.online|prod|PROD" ]

    run resolve_and_report test
    [ "$output" = "hetzner|test.vitalikuts.online|test|DEV_HETZ" ]
}

@test "resolve_target rejects unknown targets" {
    run resolve_and_report nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown target 'nope'"* ]]
}
