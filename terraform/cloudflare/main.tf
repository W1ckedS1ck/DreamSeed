locals {
  parts     = split(".", var.domain)
  zone_name = length(local.parts) > 2 ? join(".", slice(local.parts, 1, length(local.parts))) : var.domain
}

data "cloudflare_zone" "this" {
  name = local.zone_name
}

# Cloudflare Managed Free Ruleset ID (global, static)
locals {
  cf_managed_free_ruleset_id = "77454fe2d30c4220b5701f6fdfb893ba"
}

resource "cloudflare_ruleset" "waf" {
  zone_id     = data.cloudflare_zone.this.id
  name        = "DreamSeed WAF — ${local.zone_name}"
  description = "Cloudflare Free Managed Ruleset — OWASP Top 10, protocol attacks, bots"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules {
    action = "execute"
    action_parameters {
      id = local.cf_managed_free_ruleset_id
      overrides {
        action = "block"
      }
    }
    expression  = "true"
    description = "Block OWASP Top 10 and protocol-level attacks"
    enabled     = true
  }
}

resource "cloudflare_ruleset" "cache" {
  zone_id     = data.cloudflare_zone.this.id
  name        = "MODX Cache Rules — ${local.zone_name}"
  description = "Cache HTML, bypass admin and logged-in users"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules {
    action = "set_cache_settings"
    action_parameters {
      cache = true
      edge_ttl {
        mode    = "override_origin"
        default = var.edge_ttl
      }
    }
    expression  = "(not starts_with(http.request.uri.path, \"/manager/\")) and (not http.cookie contains \"PHPSESSID\")"
    description = "Cache: all except admin and logged-in users"
    enabled     = true
  }
}
