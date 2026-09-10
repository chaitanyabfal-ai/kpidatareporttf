# GETTING_STARTED.md — start to end, every path

This is the single guide to go from a fresh clone to a running pipeline.
`RUNBOOK.md` still exists for manual/step-by-step AWS CLI reference and
deeper troubleshooting; `SECURITY.md` covers credential hygiene. Read
`SECURITY.md` before you push anything to a remote.

## Architecture

```
Garage S3 (Tailscale VPN: 100.78.2.20:3900)
    │  garage_sync.py polls every 5s
    ▼
AWS S3 bucket  (BFA3/, BFA8/, BFA12/ prefixes)
    │  s3:ObjectCreated:* event
    ▼
SNS topic (ilds-s3-events)
    │  subscription
    ▼
SQS queue (ilds_queue_1)
    │  long-poll
    ▼
EC2: ec2-sqs-poller.service  →  data/kpi_reports/*.json
```

Everything left of the SNS topic (`garage_sync.py`, `s3_uploader.py`) runs
fine with **no AWS provisioning at all** if you just want to test the
upload side. Everything right of S3 needs the SNS/SQS/EC2 pieces
provisioned — either with the bash script or Terraform, your choice.

## 0. Prerequisites (all paths)

- Python 3.11+
- AWS CLI v2, configured (`aws configure` or `AWS_PROFILE`)
- An AWS account with permission to create S3/SNS/SQS/IAM (and EC2, if you
  use it)
- `jq` (used by the bash provisioning script)
- VS Code (or any editor) with the Python extension
- **Optional, only for the Terraform path:** Terraform >= 1.5
  (`terraform -version` to check; install from
  https://developer.hashicorp.com/terraform/install if missing)

```bash
git clone https://github.com/chaitanyabfal-ai/kpidatareporttf.git
cd kpidatareporttf
python3 -m venv kpidatatf
source kpidatatf/bin/activate      # Windows: kpidatatf\Scripts\activate
pip install --upgrade pip
pip install -r requirements.txt
cp .env.example .env
```

Run the tests to confirm the environment is sane before touching AWS:

```bash
python -m pytest -q tests/test_uploader_contract.py
```

---

## Path A — Local only, no AWS resources at all

Use this to develop/test the CSV-validation and upload logic without
provisioning anything. You won't get KPI processing (that needs the
SNS/SQS/EC2 leg), but you can confirm Garage connectivity and S3 uploads
work.

1. Edit `.env` — set `GARAGE_ACCESS_KEY_ID` / `GARAGE_SECRET_ACCESS_KEY`,
   and point `S3_BUCKET` at any bucket you already have (or create one
   manually: `aws s3 mb s3://your-test-bucket`).
2. Confirm Garage reachability (needs Tailscale VPN up):
   ```bash
   ./scripts/test_garage_integration.sh
   ```
3. Run a one-time sync:
   ```bash
   python3 scripts/garage_sync.py --once
   ```
4. Confirm the file landed in S3:
   ```bash
   aws s3 ls s3://$(grep S3_BUCKET .env | cut -d= -f2)/ --recursive
   ```

To also test KPI computation without EC2, run the processor directly
against Garage — this is the same logic the EC2 poller uses, just invoked
manually instead of triggered by SQS:

```bash
python3 scripts/garage_kpi_processor.py \
  --json-output data/kpi_reports/garage_kpi_report.json \
  --csv-output data/kpi_reports/garage_kpi_batch_summary.csv
```

---

## Path B — Full pipeline, EC2 via bash

Use the consolidated `provision_aws_resources.sh` (this replaces the 8
duplicate variants that used to exist in this repo — see
`README_CHANGES.md`).

```bash
chmod +x scripts/*.sh

# S3 + SNS + SQS + IAM role/instance profile only (no EC2 instance yet):
./scripts/provision_aws_resources.sh

# Update .env with the bucket/queue the script printed:
#   S3_BUCKET=...
#   SQS_QUEUE_URL=...

# Verify the AWS-side wiring before trusting it with real data:
./scripts/diagnose_s3_sqs_bridge.sh   # needs AWS_REGION/BUCKET_NAME/QUEUE_NAME env vars, see script header

# When ready, launch the EC2 worker too:
EC2_LAUNCH=true \
ALERT_EMAIL=you@example.com \
./scripts/provision_aws_resources.sh
```

The EC2 instance boots with the systemd services already installed and
enabled — but with placeholder Garage credentials (real secrets are never
baked into user-data, see `SECURITY.md`). Connect and fix `.env`:

```bash
# SSH (if you set EC2_KEY_NAME) or SSM (if you didn't):
ssh -i your-key.pem ec2-user@<PUBLIC_IP>
# or: aws ssm start-session --target <INSTANCE_ID>

sudo -u bfa nano /home/bfa/ilds_s3_garage_uploader_project/.env
# set real GARAGE_ACCESS_KEY_ID / GARAGE_SECRET_ACCESS_KEY

sudo systemctl restart garage-sync ec2-sqs-poller
sudo systemctl status garage-sync ec2-sqs-poller
```

---

## Path C — Full pipeline, EC2 via Terraform

Same end result as Path B, but declarative — `terraform plan` shows you
exactly what will change before it changes, and `terraform destroy` tears
it all down cleanly (no more hunting down 8 different bucket names from 8
script variants).

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set alert_email, ec2_launch, ec2_key_name as needed

terraform init
terraform plan      # review what it's about to create
terraform apply

# Copy the outputs into your .env:
terraform output dotenv_snippet
```

To add the EC2 worker (or do it in the same `apply` — either works, since
this isn't append-only like the bash script's env-var flags):

```bash
# in terraform.tfvars:
#   ec2_launch   = true
#   ec2_key_name = "your-existing-keypair"   # or leave "" for SSM-only access

terraform apply
terraform output ec2_ssh_command
```

**Important constraint:** the systemd unit files (`systemd/*.service`) are
hardcoded to `User=bfa` and `/home/bfa/...` paths. If you change
`deploy_user` in `terraform.tfvars` away from the default `"bfa"`, you must
also update `systemd/garage-sync.service` and
`systemd/ec2-sqs-poller.service` to match, or the services will fail to
start (wrong `WorkingDirectory`/`User`). Simplest is to just leave
`deploy_user = "bfa"`.

Tear down everything Terraform created:

```bash
terraform destroy
```

(This won't touch anything the bash script created — the two approaches
manage separate state. Don't run both against the same bucket/queue names
simultaneously; pick one per environment.)

---

## Path D — AWS resources provisioned, but poller runs locally (no EC2)

A middle ground: get the real S3→SNS→SQS pipeline working, but run the
poller on your own machine instead of paying for/managing an EC2 instance.
Good for development or low-volume use.

```bash
# Provision without EC2 (either path B or C above, just skip the EC2 step)
# Then run the poller locally:
export QUEUE_URL=$(terraform -chdir=infra/terraform output -raw sqs_queue_url)   # or from the bash script's output
export BUCKET_NAME=$(terraform -chdir=infra/terraform output -raw bucket_name)
./scripts/ec2_sqs_kpi_poller.sh
```

It's the same script either way — it doesn't know or care whether it's
running on EC2 or your laptop, it just needs `QUEUE_URL`/`SQS_QUEUE_URL`
and AWS credentials with the right SQS/S3 permissions (your own `aws
configure` profile works fine here instead of an instance role).

---

## Verifying the pipeline end-to-end (any path)

```bash
./scripts/diagnose_s3_sqs_bridge.sh   # checks notification config, policies, subscription, does a live probe
```

Then a real end-to-end test:

```bash
python3 scripts/garage_sync.py --once     # or drop a CSV in data/incoming_csvs/ and run scripts/s3_uploader.py
# within ~30s, check:
cat data/kpi_reports/ec2_queue_kpi_latest.json    # (on whichever machine is running the poller)
```

If a file lands in S3 but nothing shows up downstream, see the
troubleshooting flow in `RUNBOOK.md` §11 and the `failed_messages/`
directory the poller now writes to on error (see `README_CHANGES.md` for
what changed in the poller's error handling).

## Teardown

- **Bash-provisioned resources:** manual — see `RUNBOOK.md` §11.3 for the
  full `aws s3 rb` / `aws sqs delete-queue` / `aws sns delete-topic` /
  IAM cleanup commands.
- **Terraform-provisioned resources:** `terraform destroy` from
  `infra/terraform/`.
