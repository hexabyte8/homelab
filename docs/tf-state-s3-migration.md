# Migrating OpenTofu State from Terraform Cloud to S3

> **Status:** ✅ Completed — This migration has already been performed. The
> infrastructure state is now stored in the AWS S3 bucket `chronobyte-homelab-tf-state`.
> This document is kept for historical reference.

---

## Why Migrate?

The current backend stores OpenTofu state in **Terraform Cloud** (HCP Terraform).
Migrating to **AWS S3** means:

- **No third-party dependency** — state lives in the same AWS account that already hosts
  the game-server backups
- **Reduced cost** — Terraform Cloud's free tier has run limits; S3 costs are negligible
  (< $0.01/month for a small state file)
- **Simpler authentication** — the existing `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  credentials are reused; no separate `TF_API_TOKEN` needed
- **State locking via DynamoDB** — equivalent to Terraform Cloud locking, prevents
  concurrent runs from corrupting state
- **Versioning** — S3 bucket versioning keeps every historical state revision, matching
  the protection Terraform Cloud already provides

---

## Overview of Changes

| Component | Before | After |
|-----------|--------|-------|
| `opentofu/main.tf` backend | `backend "remote"` → Terraform Cloud | `backend "s3"` → AWS S3 |
| State lock mechanism | Terraform Cloud built-in | AWS DynamoDB table |
| Auth credentials (CI) | `TF_API_TOKEN` + `~/.tofurc` | Existing `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| Auth credentials (local) | `~/.tofurc` file | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars |
| Bitwarden secret | `TF_API_TOKEN` (can be deleted after migration) | None (AWS creds already present) |

---

## New AWS Resources

Two AWS resources must be created **manually** before running `tofu init`, because
OpenTofu cannot manage the very backend that stores its own state.

### S3 Bucket (State Storage)

| Property | Value |
|----------|-------|
| Bucket name | `chronobyte-homelab-tf-state` |
| Region | `us-east-1` |
| Versioning | Enabled |
| Encryption | AES-256 (SSE-S3) |
| Public access | Blocked |
| State key path | `homelab/terraform.tfstate` |

### DynamoDB Table (State Locking)

| Property | Value |
|----------|-------|
| Table name | `homelab-tf-state-lock` |
| Billing mode | `PAY_PER_REQUEST` (on-demand, no idle cost) |
| Primary key | `LockID` (String) |
| Region | `us-east-1` |

---

## Step-by-Step Migration

### Step 1 — Back Up the Current State

Before changing anything, export the current Terraform Cloud state as a local file.

```bash
cd homelab/opentofu

# Authenticate to Terraform Cloud (only needed for this step)
cat > ~/.tofurc <<'EOF'
credentials "app.terraform.io" {
  token = "<TF_API_TOKEN from Bitwarden>"
}
EOF

tofu init

# Pull the current state to a local JSON file
tofu state pull > /tmp/homelab-tfstate-backup-$(date +%Y%m%d-%H%M%S).json

# Verify the backup is non-empty (should show resource list)
cat /tmp/homelab-tfstate-backup-*.json | python3 -m json.tool | grep '"type"' | head -20
```

Keep this backup file safe — it is your recovery point if anything goes wrong.

---

### Step 2 — Create the S3 Bucket (Manual)

Use the AWS CLI or the AWS Console. The bucket stores the state file.

=== "AWS CLI"

    ```bash
    export AWS_ACCESS_KEY_ID="<AWS_ACCESS_KEY_ID from Bitwarden>"
    export AWS_SECRET_ACCESS_KEY="<AWS_SECRET_ACCESS_KEY from Bitwarden>"

    # Create the bucket
    aws s3api create-bucket \
      --bucket chronobyte-homelab-tf-state \
      --region us-east-1

    # Enable versioning (keeps all historical state revisions)
    aws s3api put-bucket-versioning \
      --bucket chronobyte-homelab-tf-state \
      --versioning-configuration Status=Enabled

    # Enable default AES-256 encryption
    aws s3api put-bucket-encryption \
      --bucket chronobyte-homelab-tf-state \
      --server-side-encryption-configuration '{
        "Rules": [{
          "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "AES256"
          }
        }]
      }'

    # Block all public access
    aws s3api put-public-access-block \
      --bucket chronobyte-homelab-tf-state \
      --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # Verify
    aws s3api get-bucket-versioning --bucket chronobyte-homelab-tf-state
    aws s3api get-bucket-encryption --bucket chronobyte-homelab-tf-state
    ```

=== "AWS Console"

    1. Go to [S3 in the AWS Console](https://s3.console.aws.amazon.com/s3/)
    2. Click **Create bucket**
    3. Set **Bucket name**: `chronobyte-homelab-tf-state`
    4. Set **Region**: `us East (N. Virginia) us-east-1`
    5. Under **Block Public Access**: check **Block all public access**
    6. Under **Bucket Versioning**: select **Enable**
    7. Under **Default encryption**: select **Server-side encryption with Amazon S3 managed keys (SSE-S3)**
    8. Click **Create bucket**

---

### Step 3 — Create the DynamoDB Table (Manual)

DynamoDB provides state locking — it prevents two concurrent `tofu apply` runs from
corrupting the state file.

=== "AWS CLI"

    ```bash
    aws dynamodb create-table \
      --table-name homelab-tf-state-lock \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region us-east-1

    # Verify the table was created
    aws dynamodb describe-table \
      --table-name homelab-tf-state-lock \
      --region us-east-1 \
      --query "Table.TableStatus"
    ```

=== "AWS Console"

    1. Go to [DynamoDB in the AWS Console](https://console.aws.amazon.com/dynamodb/)
    2. Click **Create table**
    3. Set **Table name**: `homelab-tf-state-lock`
    4. Set **Partition key**: `LockID` (type: **String**)
    5. Under **Table settings**, select **Customize settings**
    6. Under **Read/write capacity settings**, select **On-demand**
    7. Click **Create table**

---

### Step 4 — Update IAM Permissions

The existing IAM user (`homelab-s3-terraform` or equivalent) needs additional permissions
to read/write the state bucket and the DynamoDB lock table.

Add the following statement to the IAM policy already attached to the user:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::chronobyte-homelab-tf-state",
        "arn:aws:s3:::chronobyte-homelab-tf-state/*"
      ]
    },
    {
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:*:table/homelab-tf-state-lock"
    }
  ]
}
```

```bash
# Inline-update the user policy (replace USER_NAME as needed)
aws iam put-user-policy \
  --user-name homelab-s3-terraform \
  --policy-name TerraformStateAccess \
  --policy-document file://iam-state-policy.json
```

---

### Step 5 — Update `opentofu/main.tf`

Replace the `backend "remote"` block with the S3 backend:

```hcl
# Before
backend "remote" {
  hostname     = "app.terraform.io"
  organization = "chronobyte"
  workspaces {
    name = "homelab"
  }
}

# After
backend "s3" {
  bucket         = "chronobyte-homelab-tf-state"
  key            = "homelab/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "homelab-tf-state-lock"
}
```

---

### Step 6 — Migrate the State

Run `tofu init -migrate-state`. OpenTofu will detect the backend change and offer to
copy the existing state from Terraform Cloud into S3.

```bash
cd homelab/opentofu

# Set AWS credentials
export AWS_ACCESS_KEY_ID="<AWS_ACCESS_KEY_ID from Bitwarden>"
export AWS_SECRET_ACCESS_KEY="<AWS_SECRET_ACCESS_KEY from Bitwarden>"

# Create tfvars (as usual)
cat > terraform.auto.tfvars <<EOF
cloudflare_zone_id    = "<CLOUDFLARE_ZONE_ID>"
cloudflare_zone_name  = "<CLOUDFLARE_ZONE_NAME>"
cloudflare_account_id = "<CLOUDFLARE_ACCOUNT_ID>"
proxmox_host          = "chronobyte"
default_vm_password   = "<DEFAULT_VM_PASSWORD>"
aws_region            = "us-east-1"
s3_backup_bucket_name = "<S3_BACKUP_BUCKET_NAME>"
EOF

# Migrate state — OpenTofu copies state from Terraform Cloud → S3
tofu init -migrate-state
# When prompted "Do you want to copy existing state to the new backend?" → type: yes
```

!!! warning "Terraform Cloud credentials still required here"
    `tofu init -migrate-state` reads from the old backend (Terraform Cloud) AND writes
    to the new backend (S3). You must have `~/.tofurc` configured with `TF_API_TOKEN`
    during this one-time migration step.

---

### Step 7 — Verify the Migration

```bash
# Confirm state was migrated — should list all managed resources
tofu state list

# Run a plan — should show no changes (infrastructure matches state)
tofu plan
```

If `tofu plan` shows no unexpected changes, the migration is successful.

Also verify the state file exists in S3:

```bash
aws s3 ls s3://chronobyte-homelab-tf-state/homelab/ --region us-east-1
# Expected: terraform.tfstate (and versioned copies)
```

---

### Step 8 — Update GitHub Actions Workflows

Remove the `TF_API_TOKEN` secret from the Bitwarden loading step and the
`Setup OpenTofu CLI` step (which creates `~/.tofurc`) from both workflow files.

**`opentofu-apply.yml` and `opentofu-plan.yml` — remove these lines:**

```yaml
# Remove from the Bitwarden secrets block:
<bws-uuid-tf-api-token> > TF_API_TOKEN

# Remove this entire step:
- name: Setup OpenTofu CLI
  run: |
    cat <<EOF > ~/.tofurc
    credentials "app.terraform.io" {
      token = "$TF_API_TOKEN"
    }
    EOF
```

The S3 backend uses `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which are already
loaded from Bitwarden and passed to the `tofu apply` / `tofu plan` steps.

---

### Step 9 — Test the Updated Workflows

1. Create a PR with the workflow and `main.tf` changes
2. Confirm the **OpenTofu Plan** workflow runs successfully in CI
3. Merge to `main` and confirm the **OpenTofu Apply** workflow runs successfully
4. Verify `tofu plan` shows no unexpected changes

---

### Step 10 — Clean Up Terraform Cloud (Optional)

Once you have confirmed the S3 backend is working correctly:

1. Delete the `TF_API_TOKEN` entry from Bitwarden Secrets Manager
   (or at minimum update the note to mark it as deprecated)
2. Log in to [app.terraform.io](https://app.terraform.io) and archive or delete the
   `chronobyte/homelab` workspace:
   - **Settings → Destruction and Deletion → Delete from HCP Terraform**
   - Note: this does not destroy your actual infrastructure — it only removes the
     Terraform Cloud workspace record

---

## Rollback Plan

If something goes wrong, you can restore the Terraform Cloud backend:

1. Revert the `backend "s3"` block in `main.tf` back to `backend "remote"`
2. Restore `~/.tofurc` with the Terraform Cloud token
3. Run `tofu init -migrate-state` — it will prompt to copy state back from S3 to
   Terraform Cloud
4. Verify with `tofu state list` and `tofu plan`

The state backup created in Step 1 can also be pushed manually:

```bash
# Force-push a state backup to the remote backend
tofu state push /tmp/homelab-tfstate-backup-<timestamp>.json
```

---

## S3 Backend Configuration Reference

Full `backend "s3"` block (for `opentofu/main.tf`):

```hcl
backend "s3" {
  bucket         = "chronobyte-homelab-tf-state"
  key            = "homelab/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "homelab-tf-state-lock"
}
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `bucket` | `chronobyte-homelab-tf-state` | S3 bucket storing the state file |
| `key` | `homelab/terraform.tfstate` | Path within the bucket |
| `region` | `us-east-1` | AWS region (matches existing infrastructure) |
| `encrypt` | `true` | Enforce server-side encryption |
| `dynamodb_table` | `homelab-tf-state-lock` | DynamoDB table for state locking |

Authentication is handled automatically via `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` environment variables — no extra configuration needed.

---

## Cost Estimate

| Resource | Cost |
|----------|------|
| S3 storage (small state file, ~100 KB) | < $0.01/month |
| S3 requests (plan/apply ops) | < $0.01/month |
| DynamoDB (on-demand, ~2 lock ops per run) | < $0.01/month |
| **Total** | **Effectively free** |

Compare to Terraform Cloud free tier: 500 managed resources, limited run concurrency,
and potential for hitting team/organisation limits.
