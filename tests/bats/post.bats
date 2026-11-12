#!/usr/bin/env bats
# Unit tests for lib/post.sh:update_dns.
# The DNS step must keep www.<domain> pointing at the same origin as the apex:
# a stale or missing www record is exactly what makes Cloudflare answer
# "Error 522" for www while the apex stays healthy (seen on prod 2026-11-11).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CALLS_FILE="$BATS_TEST_TMPDIR/calls"
    : > "$CALLS_FILE"

    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/post.sh"

    # Stubs: no network, no logging framework, record what would be written.
    step_start() { :; }
    step_ok() { :; }
    step_fail() { printf 'FAIL: %s\n' "$*" >> "$CALLS_FILE"; }
    update_cloudflare_dns() { printf 'dns %s %s\n' "$1" "$2" >> "$CALLS_FILE"; }
    update_cloudflare_dns_direct() { printf 'direct %s %s\n' "$1" "$2" >> "$CALLS_FILE"; }

    SKIP_DNS="false"
    CLOUDFLARE_API_TOKEN="test-token"
    DEPLOY_DOMAIN="dreamseed.online"
    SERVER_IP="203.0.113.10"
    TARGET="prod-hetz"
}

@test "update_dns: prod writes the apex and the www record with the same IP" {
    run update_dns
    [ "$status" -eq 0 ]
    run cat "$CALLS_FILE"
    [ "${lines[0]}" = "dns dreamseed.online 203.0.113.10" ]
    [ "${lines[1]}" = "dns www.dreamseed.online 203.0.113.10" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "update_dns: dev also writes the grey-cloud ssh record" {
    TARGET="dev-hetz"
    DEPLOY_DOMAIN="hetz.vitalikuts.online"
    run update_dns
    [ "$status" -eq 0 ]
    run cat "$CALLS_FILE"
    [ "${lines[0]}" = "dns hetz.vitalikuts.online 203.0.113.10" ]
    [ "${lines[1]}" = "dns www.hetz.vitalikuts.online 203.0.113.10" ]
    [ "${lines[2]}" = "direct ssh.hetz.vitalikuts.online 203.0.113.10" ]
}

@test "update_dns: --no-dns touches nothing" {
    SKIP_DNS="true"
    run update_dns
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS_FILE" ]
}

@test "update_dns: a www failure is not swallowed" {
    update_cloudflare_dns() { return 1; }
    run update_dns
    run grep -c "FAIL" "$CALLS_FILE"
    [ "$output" -ge 1 ]
}
