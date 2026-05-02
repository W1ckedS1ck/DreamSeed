# Cloud.ru Terraform - Simple Instance Creation

Простой terraform конфиг для создания инстанса на Cloud.ru.

## Требования

1. Terraform ≥ 1.0
2. Service Account с auth_key_id и auth_secret в Cloud.ru

## Настройка

### 1. Задать credentials

```bash
export TF_VAR_auth_key_id="your-key-id"
export TF_VAR_auth_secret="your-secret"
```

Или создать `.env` файл и параметры установить в `terraform.tfvars` (не рекомендуется для secrets).

### 2. Инициализировать

```bash
terraform init
```

### 3. Проверить план

```bash
terraform plan
```

### 4. Создать инстанс

```bash
terraform apply
```

## Параметры

Все параметры можно переопределить в `terraform.tfvars` или через `-var`:

- `project_id` - Project ID из Cloud.ru консоли
- `instance_name` - Имя инстанса (default: DreamSeed)
- `zone` - Зона доступности (default: ru.AZ-1)
- `flavor` - Конфигурация (default: gen-1-1)
- `ssh_key_name` - Имя SSH ключа (default: vitali)

## Выходные значения

После успешного apply:

```bash
terraform output instance_id      # ID инстанса
terraform output instance_name    # Имя инстанса
terraform output interface_ip     # IP адрес
```

## Удаление

```bash
terraform destroy
```

## Ссылки

- [Cloud.ru Terraform Provider](https://registry.terraform.io/providers/cloud-ru/cloud/2.0.0)
- [Cloud.ru Documentation](https://cloud.ru/docs/)
- [Official Examples](https://github.com/cloud-ru/evo-terraform)
