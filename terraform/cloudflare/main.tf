locals {
  zones = {
    (var.zone_name) = var.zone_name
  }
}

data "cloudflare_zone" "this" {
  for_each = local.zones
  name     = each.value
}

resource "cloudflare_page_rule" "manager_bypass" {
  for_each = data.cloudflare_zone.this
  zone_id  = each.value.id
  target   = "*${each.key}/manager/*"
  priority = 1
  status   = "active"

  actions {
    cache_level = "bypass"
  }
}

resource "cloudflare_page_rule" "cache_all" {
  for_each = data.cloudflare_zone.this
  zone_id  = each.value.id
  target   = "*${each.key}/*"
  priority = 2
  status   = "active"

  actions {
    cache_level            = "cache_everything"
    edge_cache_ttl         = var.edge_ttl
    bypass_cache_on_cookie = "PHPSESSID"
  }
}
