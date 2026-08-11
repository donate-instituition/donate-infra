# Terraform — S3 Infrastructure for EloDoar

This Terraform project provisions the AWS S3 bucket and IAM credentials used by **donate-server** and **donate-workers** to store campaign cover images, delivery proof photos, and generated tax receipt PDFs.

## Table of Contents

- [Concepts](#concepts)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Retrieving Outputs](#retrieving-outputs)
- [Using Outputs with Applications](#using-outputs-with-applications)
- [Remote State](#remote-state)
- [Credential Rotation](#credential-rotation)
- [Destroying Resources](#destroying-resources)
- [Cost Estimation](#cost-estimation)
- [Troubleshooting](#troubleshooting)

---

## Concepts

If you are new to Terraform, here is a quick glossary of the terms used throughout this guide:

| Term | Meaning |
|------|---------|
| **Provider** | A plugin that lets Terraform talk to a cloud API. We use the `aws` provider to manage AWS resources. |
| **Resource** | A single piece of infrastructure (e.g., an S3 bucket, an IAM user) declared in a `.tf` file. |
| **State** | A JSON file (`terraform.tfstate`) that maps what Terraform manages to what actually exists in AWS. Terraform reads this file to know what has already been created. |
| **Plan** | A preview of what Terraform *will* do. Running `terraform plan` shows additions, changes, and deletions without making any real changes. |
| **Apply** | The command (`terraform apply`) that actually creates or updates resources in AWS based on the plan. |
| **Output** | A value exported by Terraform after apply (e.g., the bucket name or access key). You retrieve outputs with `terraform output`. |

---

## Prerequisites

1. **AWS CLI** installed and configured with credentials that have permissions to create S3 buckets and IAM users.
   - Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

2. **Terraform >= 1.5.0** installed.
   - Install: https://developer.hashicorp.com/terraform/install

3. **AWS credentials** configured (see next section).

### Configuring AWS Credentials

Terraform reads AWS credentials from the same sources as the AWS CLI. The easiest method for local development:

```bash
# Option A: Use environment variables
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_DEFAULT_REGION="us-east-1"

# Option B: Use a named profile
aws configure --profile elodoar
export AWS_PROFILE=elodoar
```

The credentials you use here must belong to an **operator account** (your personal IAM user or SSO session) — not the application IAM user that Terraform will create.

Your operator account needs at minimum these permissions:
- `s3:*` (to create/manage the bucket)
- `iam:*` (to create the application IAM user and access key)

---

## Quick Start

```bash
# 1. Navigate to the Terraform directory
cd donate-infra/terraform

# 2. (Optional) Create your own variables file from the example
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars if you want to change defaults (region, environment, etc.)

# 3. Initialize Terraform — downloads the AWS provider plugin
terraform init

# 4. Preview what will be created (no changes are made yet)
terraform plan

# 5. Apply — creates the S3 bucket, IAM user, and policy in AWS
terraform apply
# Terraform will show the plan and ask: "Do you want to perform these actions?"
# Type: yes

# 6. Retrieve the credentials for your applications
terraform output -raw S3_BUCKET
terraform output -raw S3_REGION
terraform output -raw S3_ACCESS_KEY_ID
terraform output -raw S3_SECRET_ACCESS_KEY
terraform output -raw S3_ENDPOINT
```

After step 5, Terraform creates a `terraform.tfstate` file in this directory. **Do not delete this file** — it is how Terraform knows what it created. It is gitignored by default.

---

## Configuration

All configuration is done via Terraform variables. See [`terraform.tfvars.example`](./terraform.tfvars.example) for a commented reference of all available options.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | `"us-east-1"` | AWS region for the S3 bucket |
| `environment` | string | `"dev"` | Deployment environment (`dev`, `staging`, or `production`) |
| `bucket_name_prefix` | string | `"elodoar-storage"` | Prefix for bucket name. Final name: `{prefix}-{environment}` |
| `enable_versioning` | bool | `false` | Enable S3 versioning (increases cost but allows recovery) |
| `receipts_transition_days` | number | `30` | Days before `receipts/` objects move to Intelligent-Tiering |
| `abort_multipart_days` | number | `7` | Days before incomplete multipart uploads are aborted |

To override defaults, either:
- Create a `terraform.tfvars` file (gitignored)
- Or pass variables on the command line: `terraform apply -var="environment=staging"`

---

## Retrieving Outputs

After a successful `terraform apply`, retrieve values using:

```bash
# Non-sensitive outputs (displayed normally)
terraform output -raw S3_BUCKET
terraform output -raw S3_REGION
terraform output -raw S3_ENDPOINT

# Sensitive outputs (masked by default, -raw reveals the value)
terraform output -raw S3_ACCESS_KEY_ID
terraform output -raw S3_SECRET_ACCESS_KEY
```

To get all outputs as JSON (useful for scripting):

```bash
terraform output -json
```

> **Note:** Sensitive values are included in plaintext in the JSON output. Do not pipe this output to logs or commit it anywhere.

---

## Using Outputs with Applications

Both **donate-server** and **donate-workers** consume the same S3 environment variables. After running `terraform apply`, set these in each application's `.env` file:

```bash
# In donate-server/.env and donate-workers/.env

OBJECT_STORAGE_DRIVER=s3
S3_REGION=<value from: terraform output -raw S3_REGION>
S3_BUCKET=<value from: terraform output -raw S3_BUCKET>
S3_ACCESS_KEY_ID=<value from: terraform output -raw S3_ACCESS_KEY_ID>
S3_SECRET_ACCESS_KEY=<value from: terraform output -raw S3_SECRET_ACCESS_KEY>
S3_ENDPOINT=
S3_FORCE_PATH_STYLE=false
```

Or use a script to populate them automatically:

```bash
# Run from the donate-infra/terraform directory
cd donate-infra/terraform

export S3_BUCKET=$(terraform output -raw S3_BUCKET)
export S3_REGION=$(terraform output -raw S3_REGION)
export S3_ACCESS_KEY_ID=$(terraform output -raw S3_ACCESS_KEY_ID)
export S3_SECRET_ACCESS_KEY=$(terraform output -raw S3_SECRET_ACCESS_KEY)
export S3_ENDPOINT=$(terraform output -raw S3_ENDPOINT)
```

The `S3_ENDPOINT` output is an empty string — this is intentional. It is only needed when using an S3-compatible provider like MinIO or LocalStack for local development.

---

## Remote State

By default, Terraform stores state locally in `terraform.tfstate`. This works fine for a single developer but can cause conflicts if multiple people run Terraform against the same infrastructure.

To enable remote state storage, you need to:

### 1. Create the backend resources (one-time setup)

Create an S3 bucket and DynamoDB table that will hold the state:

```bash
# Create the state bucket
aws s3api create-bucket \
  --bucket elodoar-terraform-state \
  --region us-east-1

# Enable versioning on the state bucket (protects against state corruption)
aws s3api put-bucket-versioning \
  --bucket elodoar-terraform-state \
  --versioning-configuration Status=Enabled

# Create the lock table (prevents concurrent applies)
aws dynamodb create-table \
  --table-name elodoar-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 2. Uncomment the backend block in `versions.tf`

Open `versions.tf` and uncomment the `backend "s3"` block:

```hcl
backend "s3" {
  bucket         = "elodoar-terraform-state"
  key            = "s3-storage/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "elodoar-terraform-locks"
  encrypt        = true
}
```

### 3. Reinitialize Terraform

```bash
terraform init
# Terraform will ask if you want to migrate existing state to the new backend.
# Type: yes
```

After this, the local `terraform.tfstate` file will be empty and state is stored remotely in S3.

---

## Credential Rotation

If the application IAM credentials are compromised or you simply want to rotate them:

```bash
# 1. Mark the access key for recreation
terraform taint aws_iam_access_key.this

# 2. Apply — Terraform destroys the old key and creates a new one
terraform apply

# 3. Retrieve the new credentials
terraform output -raw S3_ACCESS_KEY_ID
terraform output -raw S3_SECRET_ACCESS_KEY

# 4. Update donate-server and donate-workers .env files with the new values
# 5. Restart the applications
```

The old access key is immediately invalidated when Terraform destroys it. Make sure to update the applications promptly after rotation.

---

## Destroying Resources

To remove all AWS resources created by this Terraform project:

```bash
terraform destroy
# Terraform will show what will be destroyed and ask for confirmation.
# Type: yes
```

This removes:
- The S3 bucket (including all objects inside — `force_destroy` is enabled)
- The IAM user, policy, and access key

> **Warning:** This is irreversible. All objects stored in the bucket will be permanently deleted.

After destroying, the applications (donate-server, donate-workers) will no longer be able to upload or retrieve files from S3.

---

## Cost Estimation

This infrastructure is designed for minimal cost, appropriate for an academic project.

### Baseline Scenario

Assumptions: 500 stored objects, average 500 KB each (~0.25 GB total), fewer than 1,000 PUT requests/month, fewer than 5,000 GET requests/month.

| Component | Calculation | Monthly Cost |
|-----------|-------------|--------------|
| S3 Storage (Standard) | 0.25 GB x $0.023/GB | ~$0.006 |
| PUT/COPY/POST requests | 1,000 requests x $0.005/1,000 | ~$0.005 |
| GET/SELECT requests | 5,000 requests x $0.0004/1,000 | ~$0.002 |
| IAM User + Access Key | No charge | $0.00 |
| SSE-S3 encryption | No additional charge | $0.00 |
| **Total** | | **< $0.02/month** |

This project intentionally avoids features that add cost:
- No KMS encryption (avoids $1/month per key + per-request charges)
- No Transfer Acceleration
- No cross-region replication
- No S3 Analytics or Inventory

> Pricing based on AWS S3 Standard in `us-east-1` as of 2024. Always check the [AWS S3 Pricing page](https://aws.amazon.com/s3/pricing/) for current rates.

---

## Troubleshooting

### Credential misconfiguration

**Symptom:** `Error: No valid credential sources found` or `Error: error configuring Terraform AWS Provider: no valid credential sources`

**Fix:**
```bash
# Verify your credentials are configured
aws sts get-caller-identity

# If that fails, reconfigure:
aws configure
# Or set environment variables:
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
```

**Symptom:** `Error: Access Denied` during plan or apply

**Fix:** Your operator credentials do not have sufficient permissions. Ensure the IAM user/role you are using has `s3:*` and `iam:*` permissions (or an admin-level policy for development).

---

### Bucket name collision

**Symptom:** `Error: creating Amazon S3 Bucket: BucketAlreadyExists`

**Fix:** S3 bucket names are globally unique across all AWS accounts. If someone else already owns `elodoar-storage-dev`, you need to change the prefix:

```bash
terraform apply -var="bucket_name_prefix=elodoar-storage-myname"
```

Or update `bucket_name_prefix` in your `terraform.tfvars` file.

---

### State corruption recovery

If `terraform.tfstate` becomes corrupted or you see unexpected drift:

**Option A: Restore from backup**

Terraform automatically creates a `terraform.tfstate.backup` before every apply:

```bash
# Replace corrupted state with the backup
cp terraform.tfstate.backup terraform.tfstate

# Verify state matches reality
terraform plan
```

**Option B: Re-import existing resources**

If both state files are lost but the AWS resources still exist, re-import them:

```bash
# Start fresh
rm terraform.tfstate

# Import each resource (adjust names to match your environment)
terraform import aws_s3_bucket.this elodoar-storage-dev
terraform import aws_s3_bucket_ownership_controls.this elodoar-storage-dev
terraform import aws_s3_bucket_public_access_block.this elodoar-storage-dev
terraform import aws_s3_bucket_server_side_encryption_configuration.this elodoar-storage-dev
terraform import aws_s3_bucket_versioning.this elodoar-storage-dev
terraform import aws_s3_bucket_lifecycle_configuration.this elodoar-storage-dev
terraform import aws_s3_bucket_policy.this elodoar-storage-dev
terraform import aws_iam_user.this elodoar-s3-dev
terraform import aws_iam_policy.this <policy-arn>
terraform import aws_iam_user_policy_attachment.this elodoar-s3-dev/<policy-arn>
terraform import aws_iam_access_key.this <access-key-id>

# Verify everything matches
terraform plan
# Should show: No changes.
```

> **Note:** After importing the access key, the secret will not be in state. You may need to taint and recreate it (see [Credential Rotation](#credential-rotation)).

---

### Terraform init fails

**Symptom:** `Error: Failed to install provider` or network errors during `terraform init`

**Fix:**
- Check your internet connection
- If behind a proxy, configure `HTTPS_PROXY` environment variable
- Try again: `terraform init -upgrade`

---

### State lock error (remote state only)

**Symptom:** `Error: Error acquiring the state lock`

**Fix:** This means another `terraform apply` is in progress, or a previous run crashed without releasing the lock.

```bash
# Only use this if you are SURE no other apply is running:
terraform force-unlock <LOCK_ID>
```

The lock ID is displayed in the error message.
