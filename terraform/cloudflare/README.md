<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | ~> 5.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | 5.24.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [cloudflare_ruleset.cache](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_ruleset.rate_limit](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_ruleset.waf](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_zone_setting.always_use_https](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.min_tls_version](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.ssl](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_rulesets.managed](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/data-sources/rulesets) | data source |
| [cloudflare_zone.this](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/data-sources/zone) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloudflare_api_token"></a> [cloudflare\_api\_token](#input\_cloudflare\_api\_token) | Cloudflare API token | `string` | n/a | yes |
| <a name="input_domain"></a> [domain](#input\_domain) | Full domain (e.g., aws.vitalikuts.online or vitalikuts.online) | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cache_expression"></a> [cache\_expression](#output\_cache\_expression) | Cache rule expression |
| <a name="output_ruleset_id"></a> [ruleset\_id](#output\_ruleset\_id) | Cache ruleset ID |
| <a name="output_zone"></a> [zone](#output\_zone) | Resolved zone name |
<!-- END_TF_DOCS -->
