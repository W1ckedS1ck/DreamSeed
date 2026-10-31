#!/bin/bash
# Prints a yesterday summary of the Google Ads account for the daily report (read-only).
# Prints nothing and exits 0 while GOOGLE_ADS_* secrets are not configured.
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common_functions.sh
source "$SCRIPT_DIR/common_functions.sh"
[[ -f "$SCRIPT_DIR/.env" ]] && load_env "$SCRIPT_DIR/.env"

for var in GOOGLE_ADS_CLIENT_ID GOOGLE_ADS_CLIENT_SECRET GOOGLE_ADS_REFRESH_TOKEN \
    GOOGLE_ADS_DEVELOPER_TOKEN GOOGLE_ADS_CUSTOMER_ID; do
    [[ -n "${!var:-}" ]] || exit 0
done

API_VERSION="${GOOGLE_ADS_API_VERSION:-v21}"
CUSTOMER_ID="${GOOGLE_ADS_CUSTOMER_ID//-/}"
LOGIN_CUSTOMER_ID="${GOOGLE_ADS_LOGIN_CUSTOMER_ID:-}"
LOGIN_CUSTOMER_ID="${LOGIN_CUSTOMER_ID//-/}"

# Secrets go to a 0600 curl config file, never to argv (visible in ps aux).
cfg=$(mktemp)
chmod 600 "$cfg"
trap 'rm -f "$cfg"' EXIT

# 1. Exchange the refresh token for a short-lived access token.
{
    printf 'url = "https://oauth2.googleapis.com/token"\n'
    printf 'data-urlencode = "client_id=%s"\n' "$GOOGLE_ADS_CLIENT_ID"
    printf 'data-urlencode = "client_secret=%s"\n' "$GOOGLE_ADS_CLIENT_SECRET"
    printf 'data-urlencode = "refresh_token=%s"\n' "$GOOGLE_ADS_REFRESH_TOKEN"
    printf 'data-urlencode = "grant_type=refresh_token"\n'
} >"$cfg"
token_resp=$(curl -s -m 15 -X POST --config "$cfg") || token_resp=""
access_token=$(jq -r '.access_token // empty' <<<"$token_resp" 2>/dev/null || true)
if [[ -z "$access_token" ]]; then
    err=$(jq -r '.error_description // .error // "no response"' <<<"$token_resp" 2>/dev/null || echo "no response")
    echo "ERROR: Google OAuth token refresh failed: $err" >&2
    exit 1
fi

# 2. Yesterday's account totals via GAQL (searchStream returns a JSON array of batches).
query='SELECT customer.currency_code, metrics.cost_micros, metrics.impressions, metrics.clicks, metrics.conversions FROM customer WHERE segments.date DURING YESTERDAY'
body=$(jq -cn --arg q "$query" '{query: $q}')
{
    printf 'url = "https://googleads.googleapis.com/%s/customers/%s/googleAds:searchStream"\n' "$API_VERSION" "$CUSTOMER_ID"
    printf 'header = "Authorization: Bearer %s"\n' "$access_token"
    printf 'header = "developer-token: %s"\n' "$GOOGLE_ADS_DEVELOPER_TOKEN"
    [[ -n "$LOGIN_CUSTOMER_ID" ]] && printf 'header = "login-customer-id: %s"\n' "$LOGIN_CUSTOMER_ID"
    printf 'header = "Content-Type: application/json"\n'
} >"$cfg"
api_resp=$(curl -s -m 30 -X POST --config "$cfg" --data-binary "$body") || api_resp=""

api_err=$(jq -r 'if type == "object" then (.error.message // empty) else empty end' <<<"$api_resp" 2>/dev/null || true)
if [[ -n "$api_err" || -z "$api_resp" ]]; then
    echo "ERROR: Google Ads API request failed: ${api_err:-no response}" >&2
    exit 1
fi

# 3. Sum the batches. Protobuf JSON sends int64 as strings, so convert before adding.
IFS=$'\t' read -r currency cost impressions clicks conversions < <(jq -r '
    [.[]?.results[]?] as $rows
    | [
        ($rows[0].customer.currencyCode // "N/A"),
        (($rows | map((.metrics.costMicros // "0") | tonumber) | add // 0) / 1000000 | . * 100 | round / 100),
        ($rows | map((.metrics.impressions // "0") | tonumber) | add // 0),
        ($rows | map((.metrics.clicks // "0") | tonumber) | add // 0),
        ($rows | map(.metrics.conversions // 0) | add // 0)
      ]
    | @tsv' <<<"$api_resp")

echo "Google Ads (yesterday)"
echo "- Cost: $cost ${currency}"
echo "- Impressions: $impressions, clicks: $clicks"
echo "- Conversions: $conversions"
