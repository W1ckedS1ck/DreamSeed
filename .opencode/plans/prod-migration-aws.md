# Migrate prod from PROD AWS → DEV_AWS AWS

**Date:** 2026-05-15  
**Reason:** AWS PROD account became paid. DEV_AWS (preprod) account still has free tier / trial.

---

## Current state

| Target | AWS Account | Domain | EIP |
|--------|-------------|--------|-----|
| `prod` | PROD | dreamseed.online | `eipalloc-06635bbf8eda30850` |
| `dev-aws` | DEV_AWS | aws.vitalikuts.online | `eipalloc-079557035c55028d6` |

## Goal

- Kill both PROD and DEV_AWS accounts
- Deploy `prod` with `dreamseed.online` on DEV_AWS account (reuses its EIP)

---

## Step-by-step

### Step 1 — Destroy PROD prod

```bash
cd /Users/Vitali_Kuts/Desktop/DreamSeed
./deploy.sh prod -x
```

3-step confirmation → type `destroy prod`. Destroys EC2, SG, key pair. EIP stays allocated. Cloudflare A record for `dreamseed.online` gets deleted.

### Step 2 — Destroy DEV_AWS preprod

```bash
./deploy.sh dev-aws -x
```

Single confirm. Destroys EC2, SG, key pair. DEV_AWS EIP stays allocated.

### Step 3 — Edit deploy.sh

**File:** `deploy.sh` — `resolve_target()` function (line 109-113)

Change TARGET_PREFIX:

```diff
  prod)
      TF_PROVIDER="aws"
      DEPLOY_DOMAIN="dreamseed.online"
      TF_WORKSPACE="prod"
-     TARGET_PREFIX="PROD"
+     TARGET_PREFIX="DEV_AWS"
```

Now `./deploy.sh prod -n` reads `DEV_AWS_ACCESS_KEY`, `DEV_AWS_SECRET_KEY`, `DEV_AWS_REGION`, `DEV_AWS_EIP`.

### Step 4 — Deploy new prod on DEV_AWS

```bash
./deploy.sh prod -n
```

Terraform creates EC2 + associates DEV_AWS EIP. Ansible installs everything from scratch (nginx, php, mariadb, monitoring, backup, grafana, security). Fresh install — no data yet.

### Step 5 — Update Cloudflare DNS

Get the DEV_AWS EIP public IP:

```bash
aws ec2 describe-addresses --allocation-ids eipalloc-079557035c55028d6 \
  --region us-west-1 --profile dev-aws
```

Then in **Cloudflare Dashboard** → dreamseed.online → DNS → update A record to that IP.

Or via API — get record ID first:

```bash
ZONE_ID="3f6dd6599b5b95ee73a0e08b70292858"
TOKEN="$CLOUDFLARE_API_TOKEN"
IP="<NEW_IP>"

# Find dreamseed.online A record
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=dreamseed.online" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)

# Update it
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"A\",\"name\":\"dreamseed.online\",\"content\":\"$IP\",\"proxied\":true}"
```

### Step 6 — Restore data

Ansible playbook-03-db restores DB + project automatically if rclone.conf and backups exist on GDrive. Verify:

```bash
ssh -i ~/.ssh/Vitali.pem ubuntu@<IP> "curl -sI https://dreamseed.online | head -1"
```

If site is empty — restore manually:

```bash
ssh -i ~/.ssh/Vitali.pem ubuntu@<IP> "sudo /home/ubuntu/Scripts/RESTORE_ALL.sh"
```

### Step 7 — Verify

```bash
curl -I https://dreamseed.online
# 200 OK

ssh -i ~/.ssh/Vitali.pem ubuntu@<IP> "systemctl is-active nginx php8.3-fpm mariadb victoria-metrics grafana-server"
# All active
```

---

## Notes

- **DNS downtime**: Site down from Step 1 until Step 5-6 (~30 min)
- **Grafana alerts**: Fresh deploy will fire alerts for ~5 min until metrics flow — normal
- **Revert**: After Step 1, PROD EIP is still allocated. To rollback, change `TARGET_PREFIX` back to `PROD` and redeploy
- **Backup**: Prod data already on GDrive at `DreamSeed/backups/project/` and `db/`. For a fresh backup before destroying, SSH to prod and run `sudo /home/ubuntu/Scripts/smart_backup.sh`
