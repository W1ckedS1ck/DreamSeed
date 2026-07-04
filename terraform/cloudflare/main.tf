locals {
  # Expand to support multiple zones later
  zones = {
    (var.zone_name) = var.zone_name
  }
}

data "cloudflare_zone" "this" {
  for_each = local.zones
  name     = each.value
}

resource "cloudflare_ruleset" "cache" {
  for_each    = data.cloudflare_zone.this
  zone_id     = each.value.id
  name        = "MODX Cache Rules — ${each.key}"
  description = "Cache HTML, bypass admin and logged-in users"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules {
    action = "set_cache_settings"
    action_parameters {
      cache = false
    }
    expression  = "(starts_with(http.request.uri.path, \"/manager/\"))"
    description = "Bypass: MODX manager admin area"
    enabled     = true
  }

  rules {
    action = "set_cache_settings"
    action_parameters {
      cache = false
    }
    expression  = "(http.cookie contains \"PHPSESSID\")"
    description = "Bypass: logged-in users with session cookie"
    enabled     = true
  }

  rules {
    action = "set_cache_settings"
    action_parameters {
      cache = true
      edge_ttl {
        mode    = "override_origin"
        default = var.edge_ttl
      }
    }
    expression  = "(http.host eq \"${each.key}\")"
    description = "Cache: all other requests with Edge TTL ${var.edge_ttl}s"
    enabled     = true
  }
}
