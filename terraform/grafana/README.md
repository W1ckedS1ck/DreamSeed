<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_grafana"></a> [grafana](#requirement\_grafana) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_grafana"></a> [grafana](#provider\_grafana) | 2.19.4 |
| <a name="provider_grafana.sm"></a> [grafana.sm](#provider\_grafana.sm) | 2.19.4 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [grafana_dashboard.this](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/dashboard) | resource |
| [grafana_folder.dreamseed](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/folder) | resource |
| [grafana_synthetic_monitoring_check.http_grafana](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/synthetic_monitoring_check) | resource |
| [grafana_synthetic_monitoring_check.http_main](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/synthetic_monitoring_check) | resource |
| [grafana_synthetic_monitoring_check.multi_main](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/synthetic_monitoring_check) | resource |
| [grafana_synthetic_monitoring_check.ssl_main](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/synthetic_monitoring_check) | resource |
| [terraform_data.dashboard_download](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [grafana_synthetic_monitoring_probes.main](https://registry.terraform.io/providers/grafana/grafana/latest/docs/data-sources/synthetic_monitoring_probes) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_domain"></a> [domain](#input\_domain) | Domain to monitor (e.g. dreamseed.online) | `string` | n/a | yes |
| <a name="input_grafana_cloud_token"></a> [grafana\_cloud\_token](#input\_grafana\_cloud\_token) | Grafana Cloud Service Account token (glsa\_*) | `string` | n/a | yes |
| <a name="input_grafana_cloud_url"></a> [grafana\_cloud\_url](#input\_grafana\_cloud\_url) | Grafana Cloud instance URL (e.g. https://vitalikuts.grafana.net) | `string` | n/a | yes |
| <a name="input_sm_access_token"></a> [sm\_access\_token](#input\_sm\_access\_token) | Synthetic Monitoring access token (falls back to grafana\_cloud\_token) | `string` | `""` | no |
| <a name="input_sm_enabled"></a> [sm\_enabled](#input\_sm\_enabled) | Enable Synthetic Monitoring checks | `bool` | `true` | no |
| <a name="input_sm_url"></a> [sm\_url](#input\_sm\_url) | Synthetic Monitoring API URL (e.g. https://synthetic-monitoring-api-eu-north-0.grafana.net) | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_dashboard_uids"></a> [dashboard\_uids](#output\_dashboard\_uids) | Map of dashboard names to UIDs |
| <a name="output_dashboard_urls"></a> [dashboard\_urls](#output\_dashboard\_urls) | Map of dashboard names to URLs |
| <a name="output_folder_uid"></a> [folder\_uid](#output\_folder\_uid) | DreamSeed folder UID in Grafana Cloud |
| <a name="output_sm_check_ids"></a> [sm\_check\_ids](#output\_sm\_check\_ids) | Map of synthetic monitoring check names to IDs |
<!-- END_TF_DOCS -->
