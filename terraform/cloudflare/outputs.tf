output "zone" {
  description = "Resolved zone name"
  value = local.zone_name
}

output "url_pattern" {
  description = "Page rule URL pattern"
  value = local.url_pattern
}

output "cache_rule_id" {
  description = "Cache-all page rule ID"
  value = cloudflare_page_rule.cache_all.id
}

output "manager_bypass_id" {
  description = "Manager bypass page rule ID"
  value = cloudflare_page_rule.manager_bypass.id
}
