#!/usr/bin/env bats
# Unit tests for pure formatting helpers in lib/helpers.sh and
# scripts/common_functions.sh. No network, no filesystem writes.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/helpers.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/common_functions.sh"
}

@test "format_time: sub-minute values stay in seconds" {
    run format_time 0
    [ "$status" -eq 0 ]
    [ "$output" = "0s" ]

    run format_time 59
    [ "$output" = "59s" ]
}

@test "format_time: minutes and hours are zero-padded" {
    run format_time 60
    [ "$output" = "1m 00s" ]

    run format_time 3599
    [ "$output" = "59m 59s" ]

    run format_time 3600
    [ "$output" = "1h 00m 00s" ]

    run format_time 3661
    [ "$output" = "1h 01m 01s" ]
}

@test "format_env_display: empty means prod" {
    run format_env_display ""
    [ "$output" = "prod" ]

    run format_env_display "-dev"
    [ "$output" = "-dev" ]
}

@test "format_env_escaped: wraps the label for Telegram HTML" {
    run format_env_escaped ""
    [ "$output" = "<b>PROD</b>" ]

    run format_env_escaped "-dev"
    [ "$output" = "<b><i>-dev</i></b>" ]
}

@test "format_name: strips DreamSeed/db prefixes and archive suffixes" {
    run format_name "/backups/project/DreamSeed_2026-01-01.tar.gz"
    [ "$output" = "2026-01-01" ]

    run format_name "/backups/db/db_modx_db_2026-01-01.sql.gz"
    [ "$output" = "2026-01-01" ]

    run format_name "/backups/db/db_2026-01-01.sql.gz"
    [ "$output" = "2026-01-01" ]
}
