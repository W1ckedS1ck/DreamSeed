<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_hcloud"></a> [hcloud](#requirement\_hcloud) | ~> 1.66 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_hcloud"></a> [hcloud](#provider\_hcloud) | 1.66.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [hcloud_firewall.web](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/firewall) | resource |
| [hcloud_primary_ip.main](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/primary_ip) | resource |
| [hcloud_server.main](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/server) | resource |
| [hcloud_ssh_key.ci_key](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/ssh_key) | resource |
| [hcloud_primary_ip.main](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/data-sources/primary_ip) | data source |
| [hcloud_ssh_key.default](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/data-sources/ssh_key) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_additional_ssh_keys"></a> [additional\_ssh\_keys](#input\_additional\_ssh\_keys) | Additional SSH public keys to inject via cloud-init (in addition to ssh\_public\_key) | `list(string)` | `[]` | no |
| <a name="input_enable_primary_ip"></a> [enable\_primary\_ip](#input\_enable\_primary\_ip) | Create a new Primary IP in Hetzner Cloud (only when primary\_ip\_name is empty) | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment (prod, dev-hetz, etc.) — used in resource names to avoid conflicts | `string` | n/a | yes |
| <a name="input_hcloud_token"></a> [hcloud\_token](#input\_hcloud\_token) | Hetzner Cloud API token | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Hetzner datacenter location (nbg1, fsn1, hel1, ash) | `string` | `"nbg1"` | no |
| <a name="input_primary_ip_name"></a> [primary\_ip\_name](#input\_primary\_ip\_name) | Name of the existing Primary IP in Hetzner Cloud. Empty = dynamic IP | `string` | `""` | no |
| <a name="input_server_type"></a> [server\_type](#input\_server\_type) | Hetzner server type (cx23, cx33, etc.) | `string` | `"cx23"` | no |
| <a name="input_ssh_key_name"></a> [ssh\_key\_name](#input\_ssh\_key\_name) | Name of an existing SSH key in Hetzner Cloud. Empty = create from ssh\_public\_key | `string` | `""` | no |
| <a name="input_ssh_public_key"></a> [ssh\_public\_key](#input\_ssh\_public\_key) | Public key content (used when ssh\_key\_name is empty) | `string` | `""` | no |
| <a name="input_ubuntu_pro_token"></a> [ubuntu\_pro\_token](#input\_ubuntu\_pro\_token) | Ubuntu Pro token for ESM (auto-attach on first boot) | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_server_ipv4"></a> [server\_ipv4](#output\_server\_ipv4) | Public IP address of the Hetzner instance |
<!-- END_TF_DOCS -->
