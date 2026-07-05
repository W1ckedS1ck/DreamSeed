output "zone" {
  description = "Resolved zone name"
  value       = local.zone_name
}

output "ruleset_id" {
  description = "Cache ruleset ID"
  value       = cloudflare_ruleset.cache.id
}

output "cache_expression" {
  description = "Cache rule expression"
  value       = one(cloudflare_ruleset.cache.rules[*].expression)
}
