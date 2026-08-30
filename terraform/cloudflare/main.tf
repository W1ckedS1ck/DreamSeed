locals {
  parts     = split(".", var.domain)
  zone_name = length(local.parts) > 2 ? join(".", slice(local.parts, 1, length(local.parts))) : var.domain
}

data "cloudflare_zone" "this" {
  filter = {
    name = local.zone_name
  }
}

# Discover Cloudflare Managed Free Ruleset dynamically (account-level)
data "cloudflare_rulesets" "managed" {
  account_id = data.cloudflare_zone.this.account.id
}

locals {
  cf_managed_free_ruleset_id = try(
    [for rs in data.cloudflare_rulesets.managed.rulesets : rs.id if rs.phase == "http_request_firewall_managed"][0],
    ""
  )
}

resource "cloudflare_ruleset" "waf" {
  zone_id     = data.cloudflare_zone.this.id
  name        = "DreamSeed WAF — ${local.zone_name}"
  description = "Cloudflare Free Managed Ruleset — OWASP Top 10, protocol attacks, bots"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules = [{
    action = "execute"
    action_parameters = {
      id = local.cf_managed_free_ruleset_id
      overrides = {
        action = "block"
      }
    }
    expression  = "true"
    description = "Block OWASP Top 10 and protocol-level attacks"
    enabled     = true
  }]

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = local.cf_managed_free_ruleset_id != ""
      error_message = "Cloudflare Managed Free Ruleset not found — WAF would deploy as no-op with empty ID. Aborting."
    }
  }
}

check "waf_ruleset_id" {
  assert {
    condition     = local.cf_managed_free_ruleset_id != ""
    error_message = "Cloudflare Managed Free Ruleset ID is empty — WAF ruleset will not protect the site."
  }
}

resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = data.cloudflare_zone.this.id
  name        = "DreamSeed Rate Limits — ${local.zone_name}"
  description = "Rate limit admin area to prevent brute force"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    action = "block"
    action_parameters = {
      response = {
        status_code  = 429
        content      = "429 Too Many Requests"
        content_type = "text/plain"
      }
    }
    ratelimit = {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = 10
      requests_per_period = 20
      mitigation_timeout  = 10
    }
    expression  = "(starts_with(http.request.uri.path, \"/manager/\"))"
    description = "Rate limit /manager/ — 20 req/10s, block 10s (Free plan minimum; primary defense is fail2ban modx-admin jail: 150 failures/10min → 1h ban)"
    enabled     = true
  }]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_ruleset" "cache" {
  zone_id     = data.cloudflare_zone.this.id
  name        = "MODX Cache Rules — ${local.zone_name}"
  description = "Cache HTML, bypass admin and logged-in users"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [{
    action = "set_cache_settings"
    action_parameters = {
      cache = true
      edge_ttl = {
        # override_origin ignores PHPSESSID; cookie-split expression below covers duplicates.
        mode    = "override_origin"
        default = 3600
      }
      browser_ttl = {
        # Browser honors nginx's own Cache-Control (short), not this zone default.
        mode = "respect_origin"
      }
    }
    expression  = "(not starts_with(http.request.uri.path, \"/manager/\")) and (not starts_with(http.request.uri.path, \"/connectors/\")) and (not http.cookie contains \"PHPSESSID\") and (not http.cookie contains \"lifebalance_guest_completed\")"
    description = "Cache: all except admin, connector AJAX, and logged-in users"
    enabled     = true
  }]

  lifecycle {
    prevent_destroy = true
  }
}

# email_obfuscation disabled manually via Cloudflare Dashboard
# (token now has zone:settings:edit, could be managed here if wanted)

# Zone-level security settings. Token has Zone Settings Write (master account
# extends it — see docs/env-guide.md "Master account").
# NOTE: Bot Fight Mode (free plan) is a dashboard toggle, not available via this resource.
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = data.cloudflare_zone.this.id
  setting_id = "always_use_https"
  value      = "on"
}

# "strict" is free here: both origins terminate on Let's Encrypt certs (see
# ansible-roles/ssl), so full validation passes and MITM downgrade via a
# self-signed/mismatched origin cert is closed.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = data.cloudflare_zone.this.id
  setting_id = "ssl"
  value      = "strict"
}

# TLS 1.3 floor (2026): pre-2019 clients are a negligible share of a paying
# audience; keeps the edge handshake at 1-RTT and closes the 1.2 window.
# Affects the visitor->CF edge only; the CF->origin leg is governed by nginx
# ssl_protocols, not this setting.
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = data.cloudflare_zone.this.id
  setting_id = "min_tls_version"
  value      = "1.3"
}
