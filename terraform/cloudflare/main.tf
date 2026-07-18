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
    description = "Rate limit /manager/ — 20 req/10s, block 10s (Free plan minimum; primary defense is fail2ban modx-admin jail: 25 failures → 1h ban)"
    enabled     = true
  }]
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
        mode    = "override_origin"
        default = var.edge_ttl
      }
    }
    expression  = "(not starts_with(http.request.uri.path, \"/manager/\")) and (not http.cookie contains \"PHPSESSID\")"
    description = "Cache: all except admin and logged-in users"
    enabled     = true
  }]
}

# email_obfuscation disabled manually via Cloudflare Dashboard
# Terraform cannot manage this — token lacks zone:settings:edit permission
