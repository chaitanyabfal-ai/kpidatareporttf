# ILDS KPI Pipeline Operations Guide

This guide is for a new operator who needs to start the complete pipeline and see Garage sensor metrics in the Streamlit dashboard.

## 1. Architecture

```text
Garage S3 + Tailscale
        |
        | garage_sync.py
        v
AWS S3 -> SNS -> SQS -> EC2 KPI poller
                              |
                              +-> Live SQS report
                              +-> 6-minute window reports
                              +-> hourly/daily aggregator
                              +-> Streamlit dashboard
```

Recommended placement:

- The local workstation runs Garage sync because it has the Tailscale route to Garage.
- AWS runs S3, SNS, SQS, the EC2 poller, report aggregation, and Streamlit.
- The dashboard is bound to EC2 loopback and reached through an SSH tunnel.

The canonical Python environment name is `kpidatatf`.

Each processed CSV is also evaluated for sensor reliability. The live dashboard
reports the observed sample frequency, expected interval, timestamp gaps,
out-of-order samples, last-sample age, and arrival delay. The dashboard can
auto-refresh the Live SQS view every 30 seconds.

## 2. Prerequisites

You need:

- Tailscale connected on the Garage-sync workstation
- Garage S3 credentials
- AWS CLI configured for the correct account and `ap-south-1` region
- Git access to `https://github.com/chaitanyabfal-ai/kpidatareporttf.git`
- The EC2 private key file, for example `ilds-ec2-key-tf-new.pem`
- The current EC2 public IP address
- Python 3.9 or compatible Python on Amazon Linux

Never commit `.env`, private keys, or Garage secrets.

## 3. One-Time Local Setup

Run on the workstation that can reach Garage:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project_v2/ilds_s3_garage_uploader_project

python3 --version
aws sts get-caller-identity
```

Clone the repository if needed:

```bash
git clone https://github.com/chaitanyabfal-ai/kpidatareporttf.git
cd kpidatareporttf
```

Create the canonical environment:

```bash
python3 -m venv kpidatatf
source kpidatatf/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Verify the environment:

```bash
which python
which streamlit
python -c "import boto3; print('boto3 OK')"
streamlit --version
python -m pytest -q tests/test_uploader_contract.py
```

Expected paths contain:

```text
.../kpidatatf/bin/python
.../kpidatatf/bin/streamlit
```

## 4. Configure the Local `.env`

Create the file once:

```bash
cp .env.example .env
```

Edit `.env` and set the actual values:

```dotenv
AWS_REGION=ap-south-1
S3_BUCKET=<AWS bucket name>
SQS_QUEUE_URL=<SQS queue URL>

GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=<Garage access key>
GARAGE_SECRET_ACCESS_KEY=<Garage secret key>
```

Load the environment for the current shell when needed:

```bash
set -a
source .env
set +a
```

## 5. One-Time EC2 Setup

### 5.1 Provision or activate AWS resources with Terraform

Skip this subsection if the S3, SNS, SQS, IAM, and EC2 resources already exist.
Run Terraform from the local workstation with AWS credentials configured:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project_v2/ilds_s3_garage_uploader_project/infra/terraform

export AWS_REGION=ap-south-1
aws sts get-caller-identity

terraform init
terraform validate
terraform plan
terraform apply
```

Review the plan before confirming `apply`. Confirm the outputs:

```bash
terraform output
terraform output -raw ec2_public_ip
terraform output -raw sqs_queue_url
terraform output -raw bucket_name
```

Use the Terraform bucket and queue outputs in the local and EC2 `.env` files.
The EC2 public IP can change after a stop/start, so retrieve it again before
opening SSH or the dashboard tunnel.

Find the current EC2 address from Terraform or AWS:

```bash
terraform -chdir=infra/terraform output ec2_public_ip
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Id:InstanceId,IP:PublicIpAddress,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table
```

Run the AWS CLI discovery command from the operator workstation or another
principal with EC2 read permissions. The EC2 instance role is intended for
pipeline S3/SQS/SNS access; if it must run this command too, the Terraform
policy grants it `ec2:DescribeInstances`.

Connect to EC2:

```bash
ssh -i ilds-ec2-key-tf-new.pem ec2-user@<EC2_PUBLIC_IP>
```

On EC2, update the repository. Preserve local changes if Git reports them:

```bash
cd /home/ec2-user/ilds_s3_garage_uploader_project
git status
```

If tracked local changes exist:

```bash
git diff > /tmp/ec2-local-changes.patch
git stash push -m "EC2 local changes before deployment"
```

Pull the current code:

```bash
git pull --ff-only origin master
```

Create the Python 3.9 environment on a fresh instance:

```bash
git status --short
git pull --ff-only origin master
grep -E '^(boto3|botocore|streamlit)' requirements.txt
python3 -m venv kpidatatf
source kpidatatf/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Verify:

```bash
python --version
which python
which streamlit
python -c "import boto3; print('boto3 OK')"
```

The EC2 `.env` needs the AWS values used by the poller:

```dotenv
AWS_REGION=ap-south-1
S3_BUCKET=<AWS bucket name>
SQS_QUEUE_URL=<SQS queue URL>
```

These are AWS resource identifiers, not Garage credentials. Obtain the exact
values from the Terraform workstation and create the EC2 environment file:

```bash
# Run on the Terraform workstation
terraform -chdir=infra/terraform output -raw bucket_name
terraform -chdir=infra/terraform output -raw sqs_queue_url
```

On EC2, write those values to `/home/ec2-user/ilds_s3_garage_uploader_project/.env`:

```dotenv
AWS_REGION=ap-south-1
S3_BUCKET=<Terraform bucket_name output>
SQS_QUEUE_URL=<Terraform sqs_queue_url output>
```

The EC2 poller service loads this file automatically. After changing it:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ec2-sqs-poller
sudo systemctl status ec2-sqs-poller --no-pager
```

The recommended split deployment does not run Garage sync on EC2. Do not put Garage credentials on EC2 unless EC2 has a Tailscale route and is intentionally running the Garage sync service.

Install the service units:

```bash
sudo cp systemd/ec2-sqs-poller.service /etc/systemd/system/
sudo cp systemd/ilds-kpi-dashboard.service /etc/systemd/system/
sudo cp systemd/ilds-kpi-aggregator.service /etc/systemd/system/
sudo cp systemd/ilds-kpi-aggregator.timer /etc/systemd/system/

sudo systemctl daemon-reload
```

## 6. Start the Complete Pipeline

### 6.1 Start AWS processing on EC2

On EC2:

```bash
cd /home/ec2-user/ilds_s3_garage_uploader_project

sudo systemctl disable --now garage-sync 2>/dev/null || true
sudo systemctl enable --now ec2-sqs-poller
sudo systemctl enable --now ilds-kpi-dashboard
sudo systemctl enable --now ilds-kpi-aggregator.timer
```

Check all services:

```bash
sudo systemctl status ec2-sqs-poller --no-pager
sudo systemctl status ilds-kpi-dashboard --no-pager
sudo systemctl status ilds-kpi-aggregator.timer --no-pager
```

Check Streamlit locally on EC2:

```bash
curl --fail http://127.0.0.1:8501/_stcore/health
```

Expected output:

```text
ok
```

Watch the poller in a separate EC2 SSH session:

```bash
sudo journalctl -u ec2-sqs-poller -f
```

### 6.2 Test Garage connectivity locally

On the Tailscale-connected workstation:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project_v2/ilds_s3_garage_uploader_project
source kpidatatf/bin/activate

./scripts/test_garage_integration.sh
```

The test must confirm:

- Garage IP is reachable
- Credentials are present
- Garage S3 bucket is accessible

### 6.3 Run one ingestion cycle

Run this before starting continuous sync:

```bash
python scripts/garage_sync.py --once
```

The expected path is:

```text
Garage CSV -> local download -> AWS S3 upload -> SNS event -> SQS message
```

Confirm the object arrived in AWS:

```bash
set -a
source .env
set +a
aws s3 ls "s3://${S3_BUCKET}/" --recursive --region "${AWS_REGION}"
```

### 6.4 Start continuous Garage sync

Run this section on the Tailscale-connected local workstation, not on EC2.
EC2 intentionally does not receive Garage credentials and should not run
`garage_sync.py` in the split deployment.

After the one-time cycle succeeds:

```bash
python scripts/garage_sync.py
```

Keep this process running. It polls Garage every five seconds by default. For a different interval:

```bash
python scripts/garage_sync.py --interval 30
```

For production, the local workstation can run the existing `garage-sync.service`, but it must have Tailscale connected and the service paths must point to the local repository and `kpidatatf` environment.

### 6.5 Open the dashboard

From a second local terminal, create the SSH tunnel:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project_v2/ilds_s3_garage_uploader_project
ssh -i ilds-ec2-key-tf-new.pem \
  -N \
  -L 8501:127.0.0.1:8501 \
  ec2-user@<EC2_PUBLIC_IP>
```

Keep this terminal open. Open the dashboard at:

```text
http://127.0.0.1:8501
```

The SSH post-quantum warning is informational. The tunnel is working if there is no connection-refused message and the browser loads Streamlit.

## 7. Dashboard Views

Use the report-resolution selector:

- **Live SQS**: `data/kpi_reports/ec2_queue_kpi_latest.json`
- **6-minute**: completed window reports under `data/kpi_reports/windows/`
- **Hourly**: aggregated reports under `data/kpi_reports/hourly/`
- **Daily**: aggregated reports under `data/kpi_reports/daily/`

Click **Refresh reports** after new report files arrive.

In the **Timestamp reliability** table:

- `Frequency (Hz)` is the inverse of the median interval between sensor timestamps.
- `Expected interval (sec)` is that median interval.
- `Max gap (sec)` is the largest positive timestamp interval in the file.
- `Arrival delay (sec)` is processing time minus the last sensor timestamp.
- `Gaps` counts intervals larger than 1.5 times the expected interval.
- `Out of order` counts timestamp values that arrive earlier than the prior row.
- `stale` means the last sensor timestamp is more than three expected intervals
  old, with a minimum threshold of 60 seconds.

The live SQS report also exposes the PDF-aligned ingestion gates:

- **Freshness**: `90-min accepted` is false when the newest sensor sample is
  more than 90 minutes old. This is the real-time processing cutoff.
- **Frequency check**: compares observed cadence with the 100 Hz sensor target.
- **6-min window**: confirms that the CSV contains at least 36,000 samples,
  the minimum analysis window at 100 Hz.
- **Queue wait (sec)**: time from the SQS `SentTimestamp` to EC2 processing;
  this is separate from S3 download/processing latency.
- **Heartbeat**: each accepted upload marks its sensor `ACTIVE`; the intended
  heartbeat timeout is 15 minutes without a new upload.

The dashboard's `Avg latency` and `P95 latency` cards measure S3 download and
EC2 processing latency. `Arrival delay` measures sensor timestamp freshness;
`Queue wait` measures time spent before EC2 starts processing. These are
different signals and should be investigated separately.

## 8. KPI Report Verification

On EC2:

```bash
cd /home/ec2-user/ilds_s3_garage_uploader_project
find data/kpi_reports -type f -name '*.json' -print
```

Inspect the current live report:

```bash
python -m json.tool data/kpi_reports/ec2_queue_kpi_latest.json
```

Expected report files after processing:

```text
data/kpi_reports/ec2_queue_kpi_latest.json
data/kpi_reports/windows/sqs_*.json
data/kpi_reports/hourly/*.json
data/kpi_reports/daily/*.json
```

Run aggregation immediately instead of waiting for the timer:

```bash
kpidatatf/bin/python scripts/kpi_aggregator.py
```

Check the timer:

```bash
systemctl list-timers --all | grep ilds-kpi
```

Check SQS depth from a machine with AWS credentials:

```bash
aws sqs get-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region "$AWS_REGION"
```

## 9. Stop the Complete Pipeline

### 9.1 Stop local Garage sync

In the terminal running `garage_sync.py`, press:

```text
Ctrl+C
```

If it was started as a local systemd service:

```bash
sudo systemctl disable --now garage-sync
```

Verify no sync process remains:

```bash
pgrep -af garage_sync.py || true
```

### 9.2 Stop EC2 services

On EC2:

```bash
sudo systemctl stop ilds-kpi-dashboard
sudo systemctl stop ilds-kpi-aggregator.timer
sudo systemctl stop ec2-sqs-poller
```

To prevent them starting after reboot:

```bash
sudo systemctl disable ilds-kpi-dashboard
sudo systemctl disable ilds-kpi-aggregator.timer
sudo systemctl disable ec2-sqs-poller
```

The aggregator service is a oneshot unit and does not need to be stopped separately unless it is currently running:

```bash
sudo systemctl stop ilds-kpi-aggregator.service 2>/dev/null || true
```

### 9.3 Stop the SSH tunnel

In the local terminal running the tunnel, press:

```text
Ctrl+C
```

The browser will stop loading after the tunnel closes.

### 9.4 Stop or terminate EC2

To stop the instance and preserve its disk:

```bash
aws ec2 stop-instances --instance-ids <INSTANCE_ID> --region ap-south-1
```

To terminate it permanently:

```bash
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region ap-south-1
```

Termination is destructive. Confirm the instance ID before running it.

To destroy the complete Terraform-managed stack, use this only when the S3
data and all AWS resources are no longer needed:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project_v2/ilds_s3_garage_uploader_project/infra/terraform
terraform plan -destroy
terraform destroy
```

`terraform destroy` is different from `stop-instances`: it removes cloud
resources such as the bucket, queue, topics, IAM resources, and EC2 instance.

## 10. Troubleshooting

### Dashboard says no reports

On EC2:

```bash
find data/kpi_reports -type f -name '*.json' -print
sudo journalctl -u ec2-sqs-poller -n 100 --no-pager
```

Run the aggregator manually:

```bash
kpidatatf/bin/python scripts/kpi_aggregator.py
```

Then click **Refresh reports**.

### Dashboard shows connection refused through SSH tunnel

The tunnel target is correct only if Streamlit is listening on EC2:

```bash
ss -ltnp | grep 8501
curl --fail http://127.0.0.1:8501/_stcore/health
sudo systemctl status ilds-kpi-dashboard --no-pager
sudo journalctl -u ilds-kpi-dashboard -n 100 --no-pager
```

### Garage integration test says `No module named boto3`

The test uses `kpidatatf`, so install dependencies there:

```bash
source kpidatatf/bin/activate
python -m pip install -r requirements.txt
python -c "import boto3; print('boto3 OK')"
```

### Garage integration test says `GARAGE_ACCESS_KEY_ID is not set`

This test runs on the Tailscale-connected workstation, not on EC2. Add the
Garage credentials to the local `.env` only; do not copy them to EC2 in the
split deployment:

```dotenv
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=<Garage access key>
GARAGE_SECRET_ACCESS_KEY=<Garage secret key>
```

Then rerun:

```bash
./scripts/test_garage_integration.sh
```

### EC2 install says `boto3==1.43.85` requires Python 3.10

The EC2 deployment uses Python 3.9. The repository-compatible pins are
`boto3==1.28.0` and `botocore==1.31.0`; `boto3==1.43.85` is from a stale or
locally modified requirements file. From the project root, verify the checkout
before recreating the environment:

```bash
git status --short
git pull --ff-only origin master
grep -E '^(boto3|botocore)' requirements.txt
```

The command must print:

```text
boto3==1.28.0
botocore==1.31.0
```

If `git pull` reports local changes, preserve them before pulling as described
in the Git troubleshooting section. Then recreate the failed environment and
install using its interpreter explicitly:

```bash
deactivate 2>/dev/null || true
rm -rf kpidatatf
python3 -m venv kpidatatf
kpidatatf/bin/python -m pip install --upgrade pip
kpidatatf/bin/python -m pip install -r requirements.txt
kpidatatf/bin/python -c "import boto3, streamlit; print('boto3', boto3.__version__); print('streamlit', streamlit.__version__)"
```

Do not install the latest boto3 on this Python 3.9 deployment. Upgrade the
instance to Python 3.10+ first if newer AWS SDK versions are required.

If `git pull --ff-only` reports that the branches have diverged after a remote
history rewrite, first confirm that there are no tracked local changes. Then
align the EC2 checkout to the remote branch:

```bash
git status --short
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "STOP: preserve tracked changes first"
  exit 1
fi
git reset --hard origin/master
grep -E '^(boto3|botocore)' requirements.txt
```

Only continue when the pins are `boto3==1.28.0` and `botocore==1.31.0`, then
repeat the environment recreation commands above.

### Git pull refuses because of local changes

Preserve the changes before pulling:

```bash
git diff > /tmp/ec2-local-changes.patch
git stash push -m "local changes before deployment"
git pull --ff-only origin master
```

### SSH hangs or times out

Find the current EC2 IP; public IPs can change after a stop/start:

```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Id:InstanceId,IP:PublicIpAddress}' \
  --output table
```

### Dashboard crashes on metric delta

Pull the latest dashboard code and restart Streamlit. The dashboard converts pandas numeric deltas to native Python floats before passing them to Streamlit.

## 11. Safe Daily Startup Checklist

1. Confirm Tailscale and AWS credentials.
2. Confirm the current EC2 public IP.
3. Start EC2 services and check the Streamlit health endpoint.
4. Run `test_garage_integration.sh`.
5. Run one `garage_sync.py --once` test.
6. Start continuous Garage sync.
7. Open the SSH tunnel.
8. Open `http://127.0.0.1:8501`.
9. Refresh the dashboard and inspect Live SQS.
10. Check hourly and daily reports after aggregation runs.

## 12. Safe Daily Shutdown Checklist

1. Stop Garage sync with `Ctrl+C`.
2. Stop the dashboard, aggregator timer, and EC2 poller.
3. Stop the SSH tunnel with `Ctrl+C`.
4. Stop EC2 if it is not needed.
5. Do not terminate EC2 unless the instance and its data are no longer needed.
