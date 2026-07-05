locals {
  # Strip subdomain: aws.vitalikuts.online → vitalikuts.online
  parts     = split(".", var.domain)
  zone_name = length(local.parts) > 2 ? join(".", slice(local.parts, 1, length(local.parts))) : var.domain

  # URL pattern covering all subdomains and the apex
  url_pattern         = "*${local.zone_name}/*"
  manager_url_pattern = "*${local.zone_name}/manager/*"
}

data "cloudflare_zone" "this" {
  name = local.zone_name
}

resource "cloudflare_page_rule" "manager_bypass" {
  zone_id  = data.cloudflare_zone.this.id
  target   = local.manager_url_pattern
  priority = 1
  status   = "active"

  actions {
    cache_level = "bypass"
  }
}

resource "cloudflare_page_rule" "cache_all" {
  zone_id  = data.cloudflare_zone.this.id
  target   = local.url_pattern
  priority = 2
  status   = "active"

  actions {
    cache_level            = "cache_everything"
    edge_cache_ttl         = var.edge_ttl
    bypass_cache_on_cookie = "PHPSESSID"
  }
}
