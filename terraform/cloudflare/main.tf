locals {
  parts     = split(".", var.domain)
  zone_name = length(local.parts) > 2 ? join(".", slice(local.parts, 1, length(local.parts))) : var.domain
}

data "cloudflare_zone" "this" {
  name = local.zone_name
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
