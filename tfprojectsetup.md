# 🚀 ILDS S3 Garage Uploader - Complete Project Setup Runbook
**One-Stop Guide: Terraform Infrastructure + Application Deployment + KPI Tracking**
**Version:** 1.0
**Last Updated:** 2026-09-04
**Maintainer:** chaitanyabfal-ai

---

---

## 📌 **PROJECT OVERVIEW**

### Purpose
Real-time sensor data ingestion pipeline from **Garage S3** (via Tailscale VPN) to **AWS S3**, with automated **KPI tracking** and **multi-level reporting** (6-min windows → hourly → daily).

### Architecture

Garage S3 (100.78.2.20:3900)
↓ [Tailscale VPN]
EC2 (13.232.79.9)
├── garage_sync.py      → Pulls CSV from Garage → Uploads to AWS S3 → Triggers SNS
├── ec2_sqs_kpi_poller.sh → Processes SQS messages → Generates 6-min KPI reports
└── kpi_aggregator.py     → Aggregates 6-min → hourly → daily (cron: hourly)
↓
AWS S3 (453914763342-ilds-sensor-data-tf-new)
↓ [SNS Event]
AWS SQS
↓ [KPI Reports]
/opt/ilds_ingestdigest/data/kpi_reports/
├── windows/   (6-minute JSON reports)
├── hourly/    (Hourly aggregated reports)
└── daily/     (Daily aggregated reports)

### Sensors
| Sensor | Expected Files/6min | Total/6min |
|--------|---------------------|------------|
| BFA8   | 2                   | 6          |
| BFA3   | 2                   | 6          |
| BFA12  | 2                   | 6          |

---

---

# 🏗️ **PART 1: TERRAFORM INFRASTRUCTURE SETUP**

> **⚠️ IMPORTANT:** Terraform manages AWS resources. Run from a machine with AWS credentials configured.

## 1.1 Prerequisites

### Install Terraform
```bash
# Amazon Linux 2023
sudo dnf install -y unzip
wget https://releases.hashicorp.com/terraform/1.6.6/terraform_1.6.6_linux_amd64.zip
unzip terraform_*.zip
sudo mv terraform /usr/local/bin/
terraform -v  # Should show v1.6.6
Configure AWS Credentials
aws configure
# Enter:
# AWS Access Key ID: YOUR_AWS_ACCESS_KEY
# AWS Secret Access Key: YOUR_AWS_SECRET_KEY
# Default region name: us-east-1
# Default output format: json

cd ~
git clone https://github.com/chaitanyabfal-ai/kpidatareporttf.git
cd kpidatareporttf/terraform

Note: If Terraform files don't exist in the repo, create a terraform/ directory with the following structure.

1.3 Terraform Directory Structure
terraform/
├── main.tf          # Primary infrastructure
├── variables.tf     # Input variables
├── outputs.tf       # Output values
├── s3.tf           # S3 bucket configuration
├── sns_sqs.tf      # SNS + SQS notification setup
└── ec2.tf          # EC2 instance configuration
1.4 Create Terraform Files

terraform/variables.tf

variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for resource tagging"
  default     = "ilds-sensor-data"
}

variable "environment" {
  description = "Environment name"
  default     = "production"
}

variable "sensor_bucket_name" {
  description = "Name of the S3 bucket for sensor data"
  default     = "453914763342-ilds-sensor-data-tf-new"
}

variable "ec2_key_name" {
  description = "Name of the EC2 key pair"
  default     = "ilds-ec2-key"
}

variable "ec2_instance_type" {
  description = "EC2 instance type"
  default     = "t2.micro"
}

terraform/main.tf

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

terraform/s3.tf

resource "aws_s3_bucket" "sensor_data" {
  bucket = var.sensor_bucket_name
  acl    = "private"

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = {
    Name        = var.project_name
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "sensor_data" {
  bucket = aws_s3_bucket.sensor_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

terraform/sns_sqs.tf

# SNS Topic for S3 events
resource "aws_sns_topic" "s3_events" {
  name = "${var.project_name}-s3-events"
}

# SQS Queue for KPI processing
resource "aws_sqs_queue" "kpi_processing" {
  name = "${var.project_name}-kpi-processing"
  delay_seconds = 0
  max_message_size = 262144
  message_retention_seconds = 345600
  receive_wait_time_seconds = 10
  visibility_timeout_seconds = 300

  tags = {
    Name        = var.project_name
    Environment = var.environment
  }
}

# SNS Subscription to SQS
resource "aws_sns_topic_subscription" "s3_to_sqs" {
  topic_arn = aws_sns_topic.s3_events.arn
  protocol = "sqs"
  endpoint = aws_sqs_queue.kpi_processing.arn
}

# S3 Bucket Notification to SNS
resource "aws_s3_bucket_notification" "sensor_data" {
  bucket = aws_s3_bucket.sensor_data.id
  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sns_topic_subscription.s3_to_sqs]
}

# IAM Policy for SQS access
resource "aws_iam_policy" "sqs_access" {
  name        = "${var.project_name}-sqs-access"
  description = "Allow SQS send/receive for EC2"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ListQueues"
        ]
        Resource = aws_sqs_queue.kpi_processing.arn
      }
    ]
  })
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_kpi_role" {
  name = "${var.project_name}-ec2-kpi-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sqs_access_attach" {
  role       = aws_iam_role.ec2_kpi_role.name
  policy_arn = aws_iam_policy.sqs_access.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_kpi_role.name
}

terraform/ec2.tf

resource "aws_key_pair" "ec2_key" {
  key_name   = var.ec2_key_name
  public_key = file("~/.ssh/id_rsa.pub")  # Replace with your public key path
}

resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "Allow SSH and outbound traffic"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = var.project_name
    Environment = var.environment
  }
}

resource "aws_instance" "kpi_processor" {
  ami           = "ami-0c02fb55956c7d316"  # Amazon Linux 2023
  instance_type = var.ec2_instance_type
  key_name      = aws_key_pair.ec2_key.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name        = "${var.project_name}-ec2"
    Environment = var.environment
  }
}

output "ec2_public_ip" {
  value = aws_instance.kpi_processor.public_ip
}

output "ec2_public_dns" {
  value = aws_instance.kpi_processor.public_dns
}

output "s3_bucket_name" {
  value = aws_s3_bucket.sensor_data.bucket
}

output "sqs_queue_url" {
  value = aws_sqs_queue.kpi_processing.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.kpi_processing.arn
}

terraform/outputs.tf

output "infrastructure_summary" {
  value = <<EOF
========================================
INFRASTRUCTURE DEPLOYED SUCCESSFULLY
========================================
EC2 Instance IP: ${aws_instance.kpi_processor.public_ip}
EC2 Instance DNS: ${aws_instance.kpi_processor.public_dns}
S3 Bucket: ${aws_s3_bucket.sensor_data.bucket}
SQS Queue URL: ${aws_sqs_queue.kpi_processing.url}
SQS Queue ARN: ${aws_sqs_queue.kpi_processing.arn}
SNS Topic ARN: ${aws_sns_topic.s3_events.arn}
========================================
NEXT STEPS:
1. SSH to EC2: ssh -i ~/.ssh/id_rsa.pem ec2-user@${aws_instance.kpi_processor.public_ip}
2. Install dependencies (see Part 2)
3. Deploy application (see Part 3)
========================================
EOF
}

1.5 Deploy Terraform Infrastructure
cd ~/kpidatareporttf/terraform

# Initialize
terraform init

# Plan
terraform plan -out=ilds-infra.tfplan

# Apply
terraform apply ilds-infra.tfplan

# Save outputs
terraform output -json > ../terraform-outputs.json

# Create a bucket for Terraform state (one-time)
aws s3 mb s3://ilds-terraform-state-$(date +%s)
aws s3api put-bucket-versioning --bucket ilds-terraform-state-$(date +%s) --versioning-configuration Status=Enabled

# Update terraform backend
cat >> main.tf << 'EOF'

terraform {
  backend "s3" {
    bucket = "ilds-terraform-state-<YOUR_TIMESTAMP>"
    key    = "ilds-infra/terraform.tfstate"
    region = "us-east-1"
  }
}
EOF

# Push state
terraform push

PART 2: EC2 INSTANCE SETUP
Prerequisite: EC2 instance must be running (from Part 1)

2.1 SSH into EC2 Instance
# From your local machine
EC2_IP=$(terraform output -raw ec2_public_ip)
ssh -i ~/.ssh/id_rsa.pem ec2-user@$EC2_IP
2.2 Install System Dependencies
# Update system
sudo dnf update -y

# Install core dependencies
sudo dnf install -y git python3.14 python3.14-pip python3.14-devel gcc unzip

# Verify
python3.14 --version
git --version
2.3 Install Tailscale VPN
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Enable and start
sudo systemctl enable --now tailscaled

# Authenticate (opens browser link)
sudo tailscale up
⚠️ ACTION REQUIRED: Open the Tailscale URL in your browser and authenticate. The Garage S3 endpoint (100.78.2.20) must be reachable via Tailscale.

2.4 Clone Project Repository
cd /opt
git clone https://github.com/chaitanyabfal-ai/kpidatareporttf ilds_ingestdigest
cd ilds_ingestdigest
2.5 Create Python Virtual Environment
# Create venv
python3.14 -m venv /opt/ilds_ingestdigest/kpi_data

# Install packages
/opt/ilds_ingestdigest/kpi_data/bin/pip install boto3 botocore s3transfer
2.6 Create Directory Structure
cd /opt/ilds_ingestdigest
mkdir -p data/incoming_csvs data/kpi_reports/{windows,hourly,daily} logs
2.7 Create Environment Configuration
cat > /opt/ilds_ingestdigest/.env << 'EOF'
# === Garage S3 Configuration ===
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=YOUR_GARAGE_ACCESS_KEY
GARAGE_SECRET_ACCESS_KEY=YOUR_GARAGE_SECRET_KEY
GARAGE_REGION=us-east-1

# === AWS Configuration ===
AWS_ACCESS_KEY_ID=YOUR_AWS_ACCESS_KEY
AWS_SECRET_ACCESS_KEY=YOUR_AWS_SECRET_KEY
AWS_REGION=us-east-1
AWS_S3_BUCKET=453914763342-ilds-sensor-data-tf-new
EOF

chmod 600 /opt/ilds_ingestdigest/.env
⚠️ SECURITY: Never commit .env to Git. Add it to .gitignore.

2.8 Fix Script Shebangs
# garage_sync.py - Use venv Python
sed -i '1s|.*|#!/opt/ilds_ingestdigest/kpi_data/bin/python3|' /opt/ilds_ingestdigest/scripts/garage_sync.py

# ec2_sqs_kpi_poller.sh - Use bash
sed -i '1s|.*|#!/bin/bash|' /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh
chmod +x /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh

# kpi_aggregator.py - Use venv Python
sed -i '1s|.*|#!/opt/ilds_ingestdigest/kpi_data/bin/python3|' /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
chmod +x /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
2.9 Fix Paths in garage_sync.py
# Use absolute paths
sed -i "s|LOCAL_DOWNLOAD_DIR = \"./data/incoming_csvs\"|LOCAL_DOWNLOAD_DIR = \"/opt/ilds_ingestdigest/data/incoming_csvs\"|" /opt/ilds_ingestdigest/scripts/garage_sync.py
sed -i "s|self.window_dir = Path(\"./data/kpi_reports/windows\")|self.window_dir = Path(\"/opt/ilds_ingestdigest/data/kpi_reports/windows\")|" /opt/ilds_ingestdigest/scripts/garage_sync.py
▶️ PART 3: DEPLOY & START THE PIPELINE
3.1 Start Garage Sync (Garage → AWS S3)
cd /opt/ilds_ingestdigest
pkill -f garage_sync.py
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
Verify:

tail -f /opt/ilds_ingestdigest/logs/garage_sync.log
Expected: [GARAGE] Connected to http://100.78.2.20:3900 → [GARAGE] Starting continuous sync...

3.2 Start SQS Poller (SQS → KPI Reports)
pkill -f ec2_sqs_kpi_poller.sh
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &
Verify:

tail -f /opt/ilds_ingestdigest/logs/sqs_poller.log
3.3 Configure KPI Aggregator (Cron)
# Edit crontab
crontab -e
Add:

# KPI Aggregator: Run every hour to aggregate 6-min → hourly → daily
0 * * * * /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py >> /opt/ilds_ingestdigest/logs/aggregator.log 2>&1
Verify:

crontab -l
3.4 Test Pipeline End-to-End
Upload test CSV to Garage S3
cd /opt/ilds_ingestdigest
TIMESTAMP=$(date +%s)
FILENAME="test_bfa8_$TIMESTAMP.csv"

# Create test CSV
echo "timestamp,sensor_id,value
$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA8,100
$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA8,200
$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA3,150
$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA3,150
$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA12,120
$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA12,120" > /tmp/$FILENAME

# Upload via venv Python
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "
import boto3
from botocore.config import Config
from config.aws_config import *
s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL,
    aws_access_key_id=GARAGE_ACCESS_KEY_ID,
    aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY,
    region_name=GARAGE_REGION,
    config=Config(s3={'addressing_style': 'path'}))
s3.upload_file('/tmp/$FILENAME', GARAGE_S3_BUCKET, 'BFA8/$FILENAME')
print('✓ Uploaded: BFA8/$FILENAME')
"
Monitor Pipeline
# Garage Sync
tail -f /opt/ilds_ingestdigest/logs/garage_sync.log

# SQS Poller
tail -f /opt/ilds_ingestdigest/logs/sqs_poller.log
3.5 Verify KPI Reports
After 6 minutes:

ls -la /opt/ilds_ingestdigest/data/kpi_reports/windows/
ls -la /opt/ilds_ingestdigest/data/kpi_reports/hourly/
ls -la /opt/ilds_ingestdigest/data/kpi_reports/daily/
View a report:

cat /opt/ilds_ingestdigest/data/kpi_reports/windows/*.json | /opt/ilds_ingestdigest/kpi_data/bin/python3 -m json.tool | head -50
Run aggregator manually:

/opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
🛠️ PART 4: TROUBLESHOOTING GUIDE
❌ Symptom: "No module named 'boto3'"
Cause: Script using system Python instead of venv
Fix:

# Verify venv has boto3
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "import boto3; print('✓ boto3:', boto3.__version__)"

# Check shebangs
head -1 /opt/ilds_ingestdigest/scripts/garage_sync.py
# Should be: #!/opt/ilds_ingestdigest/kpi_data/bin/python3

# Restart with venv Python
pkill -f garage_sync.py
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
❌ Symptom: Connection timeout to Garage (100.78.2.20)
Cause: Tailscale VPN not connected
Fix:

# Check status
tailscale status

# Reconnect
tailscale up --reset

# Verify Garage connection
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "
import boto3
from botocore.config import Config
from config.aws_config import *
s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL,
    aws_access_key_id=GARAGE_ACCESS_KEY_ID,
    aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY,
    region_name=GARAGE_REGION,
    config=Config(s3={'addressing_style': 'path'}))
print(s3.list_buckets())
"
❌ Symptom: "No new files" but files exist in Garage
Cause: Wrong working directory or relative paths
Fix:

# Fix paths in garage_sync.py
sed -i "s|LOCAL_DOWNLOAD_DIR = \"./data/incoming_csvs\"|LOCAL_DOWNLOAD_DIR = \"/opt/ilds_ingestdigest/data/incoming_csvs\"|" /opt/ilds_ingestdigest/scripts/garage_sync.py
sed -i "s|self.window_dir = Path(\"./data/kpi_reports/windows\")|self.window_dir = Path(\"/opt/ilds_ingestdigest/data/kpi_reports/windows\")|" /opt/ilds_ingestdigest/scripts/garage_sync.py

# Restart from correct directory
cd /opt/ilds_ingestdigest
pkill -f garage_sync.py
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
❌ Symptom: "SyntaxError: invalid syntax" in sqs_poller
Cause: Running shell script with Python
Fix:

# Ensure shebang is bash
sed -i '1s|.*|#!/bin/bash|' /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh
chmod +x /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh

# Restart
pkill -f ec2_sqs_kpi_poller.sh
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &
❌ Symptom: Upload not reaching Garage
Cause: Shell variable expansion in Python -c command
Fix:

TIMESTAMP=$(date +%s)
FILENAME="test_bfa8_$TIMESTAMP.csv"
echo "timestamp,sensor_id,value,$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA8,100" > /tmp/$FILENAME
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "
import boto3
from botocore.config import Config
from config.aws_config import *
s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL,
    aws_access_key_id=GARAGE_ACCESS_KEY_ID,
    aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY,
    region_name=GARAGE_REGION,
    config=Config(s3={'addressing_style': 'path'}))
s3.upload_file('/tmp/$FILENAME', GARAGE_S3_BUCKET, 'BFA8/$FILENAME')
print('Uploaded')
"
❌ Symptom: Terraform state conflicts
Fix:

# If state is corrupted
terraform state rm aws_instance.kpi_processor
terraform apply

# Or reset entirely (BLAST RADIUS)
terraform destroy -auto-approve
terraform apply
📊 PART 5: PIPELINE FLOW DIAGRAM
┌─────────────────────┐     ┌─────────────────────────────────────────────────────┐
│   Garage S3          │     │                      Tailscale VPN                   │
│   (100.78.2.20:3900) │◄────┤  (Authenticated connection to Garage network)       │
└─────────────────────┘     └─────────────────────────────────────────────────────┘
        │                                                                   │
        ▼                                                                   │
┌───────────────────────────────────────────────────────────────────────────────┐
│                                                                               │
│  EC2 Instance (13.232.79.9)                                                  │
│  ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐  │
│  │  garage_sync.py     │    │  ec2_sqs_kpi_poller.sh│    │  kpi_aggregator.py   │  │
│  │  - Polls Garage     │    │  - Polls SQS         │    │  - Cron: 0 * * * *   │  │
│  │    every 30s        │    │  - Processes messages │    │  - Aggregates reports│  │
│  │  - Downloads CSV     │────▶│  - Generates 6-min   │    │    6-min → hourly   │  │
│  │  - Uploads to AWS    │    │    window reports    │────▶│    → daily          │  │
│  │  - Triggers SNS     │    │                     │    │                     │  │
│  └─────────────────────┘    └─────────────────────┘    └─────────────────────┘  │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
        │                                                                   │
        ▼                                                                   ▼
┌─────────────────────┐                                         ┌─────────────────────┐
│   AWS S3            │◄───────────────────────────────────────────▶│   AWS SQS          │
│   (453914763342)    │                                         │   (KPI Processing)  │
└─────────────────────┘                                         └─────────────────────┘
        │                                                                   │
        ▼                                                                   │
┌─────────────────────┐                                             ┌──────────▼──────────┐
│   SNS Topic         │─────────────────────────────────────────────▶│  KPI Reports        │
│   (s3-events)       │                                             │  /data/kpi_reports/ │
└─────────────────────┘                                             │    ├── windows/    │
                                                                       │    ├── hourly/     │
                                                                       │    └── daily/      │
                                                                       └───────────────────┘
📁 PART 6: FILE REFERENCE
Table 2

Category
File
Purpose
Location
Terraform
main.tf
Provider config
~/kpidatareporttf/terraform/
variables.tf
Input variables
s3.tf
S3 bucket
sns_sqs.tf
SNS + SQS
ec2.tf
EC2 instance
outputs.tf
Output values
Application
garage_sync.py
Garage → AWS S3 sync
/opt/ilds_ingestdigest/scripts/
ec2_sqs_kpi_poller.sh
SQS processor
kpi_aggregator.py
Report aggregator
s3_uploader.py
AWS S3 uploader
aws_config.py
Config loader
/opt/ilds_ingestdigest/config/
Configuration
.env
Environment variables
/opt/ilds_ingestdigest/
.gitignore
Git ignore rules
Data
incoming_csvs/
Downloaded CSVs
/opt/ilds_ingestdigest/data/
kpi_reports/
KPI JSON reports
Logs
*.log
Service logs
/opt/ilds_ingestdigest/logs/
🎯 PART 7: STARTUP CHECKLIST
✅ Login Procedure
# 1. SSH to EC2
EC2_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=ilds-sensor-data-ec2" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
ssh -i ~/.ssh/id_rsa.pem ec2-user@$EC2_IP

# 2. Check services
ps aux | grep -E 'garage_sync|sqs_poller|kpi_aggregator'

# 3. Check Tailscale
tailscale status

# 4. Check logs
tail -n 20 /opt/ilds_ingestdigest/logs/garage_sync.log
tail -n 20 /opt/ilds_ingestdigest/logs/sqs_poller.log
tail -n 20 /opt/ilds_ingestdigest/logs/aggregator.log

# 5. Check KPI reports
ls -la /opt/ilds_ingestdigest/data/kpi_reports/windows/
ls -la /opt/ilds_ingestdigest/data/kpi_reports/hourly/
ls -la /opt/ilds_ingestdigest/data/kpi_reports/daily/
✅ Startup Commands (If Services Not Running)
# 1. Navigate to project
cd /opt/ilds_ingestdigest

# 2. Start all services
pkill -f garage_sync.py
pkill -f ec2_sqs_kpi_poller.sh

nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &

# 3. Verify
ps aux | grep -E 'garage_sync|sqs_poller'
✅ Logoff Procedure
# 1. Stop all services (optional - they run as nohup)
# pkill -f garage_sync.py
# pkill -f ec2_sqs_kpi_poller.sh

# 2. Exit SSH
exit
Note: Services run as background processes (nohup). They continue running after logout.

📊 PART 8: KPI REPORT STRUCTURE
6-Minute Window Report (windows/*.json)
{
  "report_id": "kpi_2026-09-04T07:36:00Z",
  "window": {
    "key": "2026-09-04T07:36:00Z",
    "start": "2026-09-04T07:36:00Z",
    "end": "2026-09-04T07:42:00Z",
    "duration_seconds": 360
  },
  "ingestion_volume": {
    "total_files": 6,
    "failed_files": 0,
    "by_sensor": {"BFA8": 2, "BFA3": 2, "BFA12": 2},
    "success_rate_percent": 100.0,
    "expected_files": 6,
    "missing_files_count": 0
  },
  "latency_ms": {
    "avg": 45.2,
    "p50": 42.0,
    "p95": 68.0,
    "p99": 75.0
  },
  "completeness": {
    "expected_files": 6,
    "actual_files": 6,
    "missing_files_count": 0,
    "last_ingest_gap_seconds": {"BFA8": 0, "BFA3": 0, "BFA12": 0}
  },
  "sensor_health": {
    "by_sensor": {
      "BFA8": {"ingested": 2, "expected": 2, "gap_seconds": 0},
      "BFA3": {"ingested": 2, "expected": 2, "gap_seconds": 0},
      "BFA12": {"ingested": 2, "expected": 2, "gap_seconds": 0}
    },
    "imbalance_ratio": 1.0
  }
}
🔄 PART 9: ROUTINE OPERATIONS
Upload Test File
cd /opt/ilds_ingestdigest
TIMESTAMP=$(date +%s)
echo "timestamp,sensor_id,value,$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA8,100" > /tmp/test_$TIMESTAMP.csv
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "
import boto3, os
from botocore.config import Config
from config.aws_config import *
os.chdir('/opt/ilds_ingestdigest')
s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL, aws_access_key_id=GARAGE_ACCESS_KEY_ID, aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY, region_name=GARAGE_REGION, config=Config(s3={'addressing_style': 'path'}))
s3.upload_file('/tmp/test_$TIMESTAMP.csv', GARAGE_S3_BUCKET, 'BFA8/test_$TIMESTAMP.csv')
print('Uploaded')
"
Check Pipeline Status
# Services
echo "=== Services ==="
ps aux | grep -E 'garage_sync|sqs_poller|kpi_aggregator' | grep -v grep

# Logs
echo -e "\n=== Garage Sync Log (last 10 lines) ==="
tail -n 10 /opt/ilds_ingestdigest/logs/garage_sync.log

echo -e "\n=== SQS Poller Log (last 10 lines) ==="
tail -n 10 /opt/ilds_ingestdigest/logs/sqs_poller.log

echo -e "\n=== Aggregator Log (last 10 lines) ==="
tail -n 10 /opt/ilds_ingestdigest/logs/aggregator.log

# KPI Reports
echo -e "\n=== KPI Reports ==="
echo "Window reports: $(ls /opt/ilds_ingestdigest/data/kpi_reports/windows/ | wc -l)"
echo "Hourly reports: $(ls /opt/ilds_ingestdigest/data/kpi_reports/hourly/ | wc -l)"
echo "Daily reports: $(ls /opt/ilds_ingestdigest/data/kpi_reports/daily/ | wc -l)"
Force Aggregation
/opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
Restart All Services
cd /opt/ilds_ingestdigest
pkill -f garage_sync.py
pkill -f ec2_sqs_kpi_poller.sh
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &
🗑️ PART 10: CLEANUP PROCEDURES
Destroy Terraform Infrastructure (BLAST RADIUS)
cd ~/kpidatareporttf/terraform
terraform destroy -auto-approve
⚠️ WARNING: This will delete ALL AWS resources created by Terraform (EC2, S3, SQS, SNS). Confirm before executing.

Remove Project Files
sudo rm -rf /opt/ilds_ingestdigest
sudo rm -rf /opt/ilds_ingestdigest
Remove Tailscale
sudo systemctl stop tailscaled
sudo systemctl disable tailscaled
sudo dnf remove -y tailscale
📚 PART 11: QUICK REFERENCE COMMANDS
Table 3

Task
Command
Check Tailscale
tailscale status
Restart Tailscale
sudo systemctl restart tailscaled
List Garage files
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "import boto3; from botocore.config import Config; from config.aws_config import *; import sys; sys.path.insert(0, '/opt/ilds_ingestdigest'); s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL, aws_access_key_id=GARAGE_ACCESS_KEY_ID, aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY, region_name=GARAGE_REGION, config=Config(s3={'addressing_style': 'path'})); [print(obj['Key']) for obj in s3.list_objects_v2(Bucket=GARAGE_S3_BUCKET).get('Contents', [])]"
Tail garage_sync
tail -f /opt/ilds_ingestdigest/logs/garage_sync.log
Tail sqs_poller
tail -f /opt/ilds_ingestdigest/logs/sqs_poller.log
Tail aggregator
tail -f /opt/ilds_ingestdigest/logs/aggregator.log
View KPI reports
ls -la /opt/ilds_ingestdigest/data/kpi_reports/windows/
Restart all
cd /opt/ilds_ingestdigest && pkill -f garage_sync.py && pkill -f ec2_sqs_kpi_poller.sh && nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 & && nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &
🏆 SUCCESS CRITERIA CHECKLIST
Table 4

#
Task
Verification
Status
1
Terraform applied
terraform show shows resources
⬜
2
EC2 instance running
aws ec2 describe-instances
⬜
3
Tailscale connected
tailscale status shows connected
⬜
4
Git repo cloned
/opt/ilds_ingestdigest exists
⬜
5
Venv created
/opt/ilds_ingestdigest/kpi_data/bin/python3 --version
⬜
6
Dependencies installed
boto3 importable in venv
⬜
7
Directories created
data/, logs/ exist
⬜
8
.env configured
Credentials present
⬜
9
Shebangs fixed
head -1 scripts/*.py shows venv
⬜
10
Paths fixed
grep LOCAL_DOWNLOAD_DIR garage_sync.py shows absolute
⬜
11
garage_sync running
ps aux | grep garage_sync
⬜
12
sqs_poller running
ps aux | grep sqs_poller
⬜
13
Cron configured
crontab -l shows aggregator
⬜
14
Test file uploaded
Garage bucket has file
⬜
15
Pipeline processing
Logs show download + upload
⬜
16
KPI reports generated
windows/*.json exists
⬜
17
Aggregator working
hourly/*.json exists after 1 hour
⬜
📞 SUPPORT & CONTACT
Table 5

Issue
Contact
Terraform
AWS Support / terraform.io
Tailscale
tailscale.com/support
Garage S3
Garage documentation
Project
chaitanyabfal-ai
📝 CHANGELOG
Table 6

Date
Version
Changes
Author
2026-09-04
1.0
Initial complete runbook

2026-09-04
1.0
Added Terraform setup


