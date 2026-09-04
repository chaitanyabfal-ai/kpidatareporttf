# AWS Provisioning and Project Setup Runbook

This runbook covers the AWS resources required by this project and the local setup steps to run the uploader scripts from this repository.

---

## 📋 Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Quick Start](#2-quick-start)
3. [AWS Resource Provisioning](#3-aws-resource-provisioning)
4. [Manual AWS Resource Setup](#4-manual-aws-resource-setup)
5. [Local Project Setup](#5-local-project-setup)
6. [Verify the Setup](#6-verify-the-setup)
7. [Run the Uploader](#7-run-the-uploader)
8. [Run the Garage Sync](#8-run-the-garage-sync)
9. [EC2 Instance Setup](#9-ec2-instance-setup)
10. [Operational Notes](#10-operational-notes)
11. [Troubleshooting](#11-troubleshooting)

---

## 1) Prerequisites

- AWS CLI v2 installed and configured
- Python 3.11+ or the repo's virtual environment
- Access to an AWS account with permission to create S3 buckets, SQS queues, SNS topics, IAM policies, and EC2 instances
- The repo checked out locally
- Current authenticated AWS identity: `arn:aws:iam::453914763342:user/cfdlds` (account `453914763342`)

**Verify the CLI is installed:**

```bash
aws --version
```

**Configure AWS credentials:**

```bash
aws configure
```

Or, if using a named profile:

```bash
export AWS_PROFILE=my-profile
aws sts get-caller-identity
```

Expected result: you should see the AWS account ID and ARN.

---

## 2) Quick Start

The fastest way to get everything running:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project

# Make scripts executable
chmod +x scripts/*.sh

# Provision all AWS resources (takes 2-3 minutes)
./scripts/provision_aws_resources.sh

# Source the virtual environment
source kpi_data/bin/activate

# Install dependencies
pip install -r requirements.txt

# Copy and update environment file
cp .env.example .env
nano .env  # Update GARAGE_* credentials

# Verify setup
python scripts/aws_s3_setup_check.py
python -m pytest -q tests/test_uploader_contract.py
```

---

## 3) AWS Resource Provisioning

The recommended approach is to use the automated provisioning script that creates all required AWS resources in one go.

### 3.1 Automated Provisioning (Recommended)

**Full provisioning with EC2 instance:**

```bash
# Set your variables
ALERT_EMAIL=your-email@example.com

# Provision all resources including EC2
EC2_LAUNCH=true \
ALERT_EMAIL=${ALERT_EMAIL} \
./scripts/provision_aws_resources.sh
```

**Provision without EC2 (for local development):**

```bash
# Provision only S3, SNS, SQS (no EC2)
./scripts/provision_aws_resources.sh
```

**Custom bucket name:**

```bash
BUCKET_NAME=453914763342-cflds-dev-ap-south-1-ilds-txdata-20260901 \
./scripts/provision_aws_resources.sh
```

**All available options:**

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `ap-south-1` | AWS region |
| `BUCKET_NAME` | Auto-generated | S3 bucket name |
| `QUEUE_NAME` | `ilds_queue_1` | SQS queue name |
| `SNS_S3_TOPIC_NAME` | `ilds-s3-events` | SNS topic for S3 events |
| `SNS_ALERT_TOPIC_NAME` | `ilds-alerts` | SNS topic for alerts |
| `EC2_LAUNCH` | `false` | Set to `true` to launch EC2 |
| `EC2_INSTANCE_TYPE` | `t3.micro` | EC2 instance type |
| `ALERT_EMAIL` | none | Email for SNS alerts |

### 3.2 What the Provisioning Script Creates

The script creates the following resources:

```
├── S3 Bucket
│   ├── Bucket: {BUCKET_NAME}
│   ├── Versioning: Enabled
│   ├── Encryption: AES-256 (SSE-S3)
│   └── Prefixes: raw-sensor-data/, processed/, logs/, dashboard/, BFA8/, BFA3/, BFA12/
│
├── SNS Topics
│   ├── S3 Events Topic: ilds-s3-events-YYYYMMDDHHMMSS
│   │   └── Policy: Allows S3 to publish notifications
│   └── Alerts Topic: ilds-alerts-YYYYMMDDHHMMSS (if ALERT_EMAIL set)
│
├── SQS Queue
│   ├── Queue: ilds_queue_1
│   ├── Visibility Timeout: 30 seconds
│   ├── Message Retention: 4 days
│   ├── Long Polling: 20 seconds
│   └── Policy: Allows SNS to send messages
│
├── S3 → SNS → SQS Pipeline
│   └── Configuration: All ObjectCreated events trigger notifications
│
└── EC2 Instance (if EC2_LAUNCH=true)
    ├── AMI: Amazon Linux 2023
    ├── Instance Type: t3.micro
    ├── Storage: 30GB gp3
    ├── IAM Role: With S3, SQS, SNS permissions
    ├── Security Group: Allows SSH (port 22)
    └── User Data: Auto-deploys project and starts services
```

### 3.3 Provisioning Output

After successful execution, the script outputs:

```
============================================================================
PROVISIONING SUMMARY
============================================================================

✅ AWS Resources Created:

  S3 Bucket:     453914763342-ilds-sensor-data-YYYYMMDDHHMMSS
  Region:        ap-south-1
  SNS Topic:     arn:aws:sns:ap-south-1:453914763342:ilds-s3-events-YYYYMMDDHHMMSS
  SQS Queue:     https://sqs.ap-south-1.amazonaws.com/453914763342/ilds_queue_1

  Alert Topic:   arn:aws:sns:ap-south-1:453914763342:ilds-alerts-YYYYMMDDHHMMSS
  Alert Email:   your-email@example.com

  IAM Role:      ilds-ec2-role-YYYYMMDDHHMMSS
  Instance Profile: ilds-ec2-profile-YYYYMMDDHHMMSS

✅ EC2 Instance:
  Instance ID:   i-xxxxxxxxxxxxxxxxx
  Public IP:     1.2.3.4
  SSH Command:   ssh -i ilds-ec2-key-YYYYMMDDHHMMSS.pem ec2-user@1.2.3.4

============================================================================
NEXT STEPS
============================================================================
```

---

## 4) Manual AWS Resource Setup

If you prefer to create resources manually or need to troubleshoot, follow these steps:

### 4.1 Create the S3 Bucket

```bash
# Set your bucket name (must be globally unique)
BUCKET_NAME="453914763342-cflds-dev-ap-south-1-ilds-txdata-$(date +%Y%m%d)"

# Create bucket
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

# Create required prefixes
for prefix in raw-sensor-data processed logs dashboard BFA8 BFA3 BFA12; do
  aws s3api put-object --bucket "$BUCKET_NAME" --key "${prefix}/" --body /dev/null
done
```

### 4.2 Create SQS Queue

```bash
# Create queue with proper attributes
QUEUE_URL=$(aws sqs create-queue \
  --queue-name ilds_queue_1 \
  --attributes VisibilityTimeout=30,MessageRetentionPeriod=345600,ReceiveMessageWaitTimeSeconds=20 \
  --query QueueUrl \
  --output text)

# Get queue ARN
SQS_QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query Attributes.QueueArn \
  --output text)
```

### 4.3 Create SNS Topic

```bash
# Create S3 events topic
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name ilds-s3-events \
  --query TopicArn \
  --output text)

# Set topic policy to allow S3 to publish
cat > /tmp/s3-topic-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowS3Publish",
    "Effect": "Allow",
    "Principal": {"Service": "s3.amazonaws.com"},
    "Action": "sns:Publish",
    "Resource": "'$SNS_TOPIC_ARN'",
    "Condition": {
      "ArnLike": {"aws:SourceArn": "arn:aws:s3:::$BUCKET_NAME"}
    }
  }]
}
EOF

aws sns set-topic-attributes \
  --topic-arn "$SNS_TOPIC_ARN" \
  --attribute-name Policy \
  --attribute-value "$(cat /tmp/s3-topic-policy.json)"
```

### 4.4 Configure S3 → SNS → SQS Pipeline

```bash
# Create SQS policy to allow SNS to send messages
cat > /tmp/sqs-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowSNSSendMessage",
    "Effect": "Allow",
    "Principal": {"Service": "sns.amazonaws.com"},
    "Action": "sqs:SendMessage",
    "Resource": "'$SQS_QUEUE_ARN'",
    "Condition": {
      "ArnEquals": {"aws:SourceArn": "$SNS_TOPIC_ARN"}
    }
  }]
}
EOF

# Create attributes file
cat > /tmp/sqs-attributes.json << 'EOF'
{
  "Attributes": {
    "Policy": $(jq -c . /tmp/sqs-policy.json)
  }
}
EOF

# Apply SQS policy using file-based approach
aws sqs set-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attributes file:///tmp/sqs-attributes.json

# Subscribe SQS to SNS topic
aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$SQS_QUEUE_ARN" \
  --attributes RawMessageDelivery=false

# Configure S3 bucket notification
aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration '{"TopicConfigurations":[{"TopicArn":"'$SNS_TOPIC_ARN'","Events":["s3:ObjectCreated:*"]}]}'
```

---

## 5) Local Project Setup

From the repo root:

```bash
cd /home/bfa/ilds_s3_garage_uploader_project
```

### 5.1 Create and Activate Virtual Environment

The workspace already contains a virtual environment at `kpi_data/`, but you can recreate it if needed:

```bash
# Recreate virtual environment
python3 -m venv kpi_data

# Activate it
source kpi_data/bin/activate
```

### 5.2 Install Python Dependencies

```bash
python -m pip install --upgrade pip
pip install -r requirements.txt
```

### 5.3 Create Local Environment File

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env` and set the actual values for your environment:

```bash
nano .env
```

**Required .env contents:**

```dotenv
# AWS Configuration
AWS_REGION=ap-south-1
S3_BUCKET=453914763342-ilds-sensor-data-YYYYMMDDHHMMSS
SQS_QUEUE_URL=https://sqs.ap-south-1.amazonaws.com/453914763342/ilds_queue_1
WATCH_DIRECTORY=./data/incoming_csvs

# Garage Configuration
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=YOUR_GARAGE_KEY
GARAGE_SECRET_ACCESS_KEY=YOUR_GARAGE_SECRET
```

> **Note:** The repo loads `.env` automatically through `config/aws_config.py`.

---

## 6) Verify the Setup

### 6.1 Run Validation Check

```bash
python scripts/aws_s3_setup_check.py
```

Expected output:
```
✓ AWS CLI is configured
✓ Bucket exists: 453914763342-ilds-sensor-data-YYYYMMDDHHMMSS
✓ Required prefixes exist
✓ SQS queue exists
```

### 6.2 Run Project Tests

```bash
python -m pytest -q tests/test_uploader_contract.py
```

This confirms the CSV naming and schema contract expected by the uploader.

---

## 7) Run the Uploader

The uploader watches `./data/incoming_csvs` for CSV files and uploads them to S3 using the correct prefix.

### 7.1 Start the Uploader Watcher

```bash
python scripts/s3_uploader.py
```

This script:
- Scans any existing CSVs in `data/incoming_csvs`
- Validates each CSV has `Timestamp` and either `Voltage` or `Pressure`
- Uploads files to `s3://<bucket>/BFA8/...` or `s3://<bucket>/BFA3/...`
- Continues watching for new CSV files until interrupted

### 7.2 Add a Sample CSV

Place a CSV file in `data/incoming_csvs/` with a name like:

```text
data/incoming_csvs/BFA8_Batch101_2026-08-31_09-00-00.csv
```

The uploader will turn that into a key such as:

```text
BFA8/BFA8_Batch101_2026-08-31_09-00-00.csv
```

**Sample CSV content:**

```csv
Timestamp,Voltage,Pressure
2026-09-02T10:00:00Z,120.5,98.2
2026-09-02T10:01:00Z,121.3,97.9
2026-09-02T10:02:00Z,119.8,98.5
```

### 7.3 Manual Upload Example

```bash
aws s3 cp data/incoming_csvs/BFA8_Batch101_2026-08-31_09-00-00.csv \
  s3://453914763342-ilds-sensor-data-YYYYMMDDHHMMSS/BFA8/BFA8_Batch101_2026-08-31_09-00-00.csv
```

---

## 8) Run the Garage Sync

This script downloads CSVs from a Garage S3-compatible endpoint and uploads them to AWS S3.

### 8.1 One-Time Sync (Testing)

```bash
python3 scripts/garage_sync.py --once
```

### 8.2 Continuous Sync (Production)

**Foreground:**

```bash
python3 scripts/garage_sync.py
```

**Background with nohup:**

```bash
nohup python3 scripts/garage_sync.py > logs/garage_sync.log 2>&1 &
```

**Background with systemd (Recommended):**

```bash
# Copy service file
sudo cp garage-sync.service /etc/systemd/system/

# Reload and start
sudo systemctl daemon-reload
sudo systemctl start garage-sync
sudo systemctl enable garage-sync  # Auto-start on reboot

# Check status
sudo systemctl status garage-sync

# View logs
sudo journalctl -u garage-sync -f
```

---

## 9) EC2 Instance Setup

### 9.1 Provision EC2 with the Script

```bash
# Launch EC2 instance with all services pre-configured
EC2_LAUNCH=true \
ALERT_EMAIL=your-email@example.com \
./scripts/provision_aws_resources.sh
```

### 9.2 Connect to EC2

After provisioning, connect to your EC2 instance:

```bash
# Use the SSH command from the provisioning output
ssh -i ilds-ec2-key-YYYYMMDDHHMMSS.pem ec2-user@<PUBLIC_IP>
```

### 9.3 Verify EC2 Services

On the EC2 instance:

```bash
# Check running processes
ps aux | grep python

# Check logs
sudo tail -f /var/log/cloud-init-output.log

# Check service logs
sudo journalctl -u garage-sync -f
sudo journalctl -u ec2-sqs-poller -f

# View KPI reports
cat /home/ec2-user/ilds_project/ilds_s3_garage_uploader_project/data/kpi_reports/*.json
```

### 9.4 Manual EC2 Setup (if not using user-data)

```bash
# On EC2 instance
sudo yum update -y
sudo yum install -y git python3 python3-pip python3-devel gcc

# Clone project
git clone https://github.com/chaitanyabfal-ai/kpidataingestreport.git
cd ilds_s3_garage_uploader_project

# Setup Python
python3 -m venv kpi_data
source kpi_data/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Create .env
cp .env.example .env
nano .env  # Update with actual values

# Create directories
mkdir -p data/incoming_csvs data/garage_kpi_downloads data/kpi_reports logs

# Start services
nohup python3 scripts/garage_sync.py > logs/garage_sync.log 2>&1 &
nohup ./scripts/ec2_sqs_kpi_poller.sh > logs/sqs_poller.log 2>&1 &
```

---

## 10) Operational Notes

### 10.1 File Naming Convention

- **Supported sensor prefixes:** `BFA8`, `BFA3`, `BFA12`
- **Filename pattern:** `{SENSOR}_Batch{XXX}_{YYYY-MM-DD}_{HH-MM-SS}.csv`
- **Examples:**
  - `BFA8_Batch101_2026-09-02_10-00-00.csv`
  - `BFA3_Batch202_2026-09-02_10-05-00.csv`
  - `BFA12_Batch303_2026-09-02_10-10-00.csv`

### 10.2 CSV Schema Requirements

Each CSV file must contain:
- **Required column:** `Timestamp`
- **At least one of:** `Voltage` or `Pressure`

### 10.3 S3 Object Key Structure

```
S3 Bucket
├── raw-sensor-data/
│   ├── BFA8/
│   │   ├── BFA8_Batch101_2026-09-02_10-00-00.csv
│   │   └── BFA8_Batch102_2026-09-02_10-05-00.csv
│   └── BFA3/
│       ├── BFA3_Batch201_2026-09-02_10-00-00.csv
│       └── BFA3_Batch202_2026-09-02_10-05-00.csv
├── processed/
├── logs/
└── dashboard/
```

### 10.4 Data Flow

```
Garage S3 (Tailscale: 100.78.2.20:3900)
    ↓
garage_sync.py (polls every 5 seconds)
    ↓
AWS S3 (raw-sensor-data/)
    ↓
S3 ObjectCreated Event → SNS Topic
    ↓
SNS → SQS Queue
    ↓
EC2: ec2_sqs_kpi_poller.sh
    ↓
KPI Reports: data/kpi_reports/ec2_queue_kpi_latest.json
```

---

## 11) Troubleshooting

### 11.1 Common Issues and Solutions

| Issue | Solution |
|-------|----------|
| **Cannot reach Garage endpoint** | Check Tailscale VPN: `tailscale status` |
| **GARAGE_ACCESS_KEY_ID not configured** | Update `.env` with Garage credentials |
| **InvalidAccessKeyId error** | Verify Garage credentials in Garage admin panel |
| **Bucket not found** | Verify bucket name in `.env` matches actual bucket |
| **Schema validation failed** | Ensure CSV has `Timestamp` and `Voltage`/`Pressure` |
| **SQS queue not receiving messages** | Verify S3→SNS→SQS pipeline is configured |
| **EC2 poller not processing** | Check EC2 IAM role has SQS permissions |

### 11.2 Debug Commands

```bash
# Test Garage connectivity
./scripts/test_garage_integration.sh

# Check S3 bucket
aws s3 ls s3://$S3_BUCKET/ --recursive

# Check SQS queue depth
aws sqs get-queue-attributes \
  --queue-url $SQS_QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-south-1

# Check SNS subscriptions
aws sns list-subscriptions-by-topic --topic-arn $SNS_TOPIC_ARN --region ap-south-1

# Check S3 notifications
aws s3api get-bucket-notification-configuration --bucket $S3_BUCKET --region ap-south-1

# Test S3 upload and SQS notification
echo "Timestamp,Voltage,Pressure" > test.csv
echo "2026-09-02T10:00:00Z,120.5,98.2" >> test.csv
aws s3 cp test.csv s3://$S3_BUCKET/raw-sensor-data/test.csv --region ap-south-1
# Wait 30 seconds, then check SQS
aws sqs receive-message --queue-url $SQS_QUEUE_URL --region ap-south-1
```

### 11.3 Cleanup Resources

To delete all provisioned resources:

```bash
# Delete S3 bucket (empty it first)
aws s3 rb s3://$S3_BUCKET --force --region ap-south-1

# Delete SQS queue
aws sqs delete-queue --queue-url $SQS_QUEUE_URL --region ap-south-1

# Delete SNS topics
aws sns delete-topic --topic-arn $SNS_TOPIC_ARN --region ap-south-1

# Delete IAM role (if created)
aws iam remove-role-from-instance-profile --instance-profile-name $EC2_INSTANCE_PROFILE_NAME --role-name $EC2_ROLE_NAME --region ap-south-1 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name $EC2_INSTANCE_PROFILE_NAME --region ap-south-1 2>/dev/null || true
aws iam delete-role-policy --role-name $EC2_ROLE_NAME --policy-name ilds-ec2-inline-policy --region ap-south-1 2>/dev/null || true
aws iam delete-role --role-name $EC2_ROLE_NAME --region ap-south-1 2>/dev/null || true

# Terminate EC2 instance
aws ec2 terminate-instances --instance-ids $EC2_INSTANCE_ID --region ap-south-1 2>/dev/null || true

# Delete key pair
aws ec2 delete-key-pair --key-name $EC2_KEY_NAME --region ap-south-1 2>/dev/null || true
rm -f $EC2_KEY_NAME.pem 2>/dev/null || true

# Delete security group
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region ap-south-1 2>/dev/null || true
```

---

## 📞 Support

For issues or questions:

1. Check logs: `sudo journalctl -u garage-sync -f`
2. Verify Tailscale VPN: `tailscale status`
3. Test connectivity: `./scripts/test_garage_integration.sh`
4. Review this runbook

---

*Last updated: 2026-09-02*

*Generated by Mistral Vibe*

*Co-Authored-By: Mistral Vibe <vibe@mistral.ai>*
