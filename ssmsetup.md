# ILDS S3 Garage Uploader - KPI Tracking Runbook
**Project:** Sensor Data Ingestion Pipeline with Garage S3 → AWS S3 → SQS → EC2 → KPI Reporting
**Repo:** https://github.com/chaitanyabfal-ai/kpidatareporttf
**EC2 Instance:** 13.232.79.9 (Amazon Linux 2023)
**Garage Endpoint:** http://100.78.2.20:3900
**AWS Account:** 453914763342

---

---

## 📋 **0. Prerequisites Checklist**

| Item | Status | Command/Path |
|------|--------|--------------|
| EC2 Instance | ✅ | 13.232.79.9 |
| Git | ✅ | `git --version` |
| Python 3.14 | ✅ | `/opt/ilds_ingestdigest/kpi_data/bin/python3 --version` |
| Tailscale | ⬜ | `tailscale status` |
| AWS CLI | ⬜ | `aws --version` |
| Project Repo | ⬜ | `/opt/ilds_ingestdigest` |

---

---

## 🚀 **1. Initial Setup (One-Time)**

### 1.1 Install Dependencies
```bash
# Amazon Linux 2023
sudo dnf update -y
sudo dnf install -y git python3.14 python3.14-pip python3.14-devel gcc
```

### 1.2 Clone Repository
```bash
cd /opt
git clone https://github.com/chaitanyabfal-ai/kpidatareporttf ilds_ingestdigest
cd ilds_ingestdigest
```

### 1.3 Create Python Virtual Environment
```bash
python3.14 -m venv /opt/ilds_ingestdigest/kpi_data
source /opt/ilds_ingestdigest/kpi_data/bin/activate
pip install boto3 botocore s3transfer
deactivate
```

### 1.4 Install Tailscale VPN
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up
```
> **Action Required:** Authenticate at the Tailscale URL printed in console

### 1.5 Create Directory Structure
```bash
cd /opt/ilds_ingestdigest
mkdir -p data/incoming_csvs data/kpi_reports/{windows,hourly,daily} logs
```

---

---

## 🔧 **2. Configuration**

### 2.1 Environment Variables (`.env`)
Create `/opt/ilds_ingestdigest/.env`:
```ini
# Garage S3
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=your_garage_key
GARAGE_SECRET_ACCESS_KEY=your_garage_secret
GARAGE_REGION=us-east-1

# AWS
AWS_ACCESS_KEY_ID=your_aws_key
AWS_SECRET_ACCESS_KEY=your_aws_secret
AWS_REGION=us-east-1
AWS_S3_BUCKET=453914763342-ilds-sensor-data-tf-new
```

### 2.2 Fix Script Shebangs
```bash
# garage_sync.py - Use venv Python
sed -i '1s|.*|#!/opt/ilds_ingestdigest/kpi_data/bin/python3|' /opt/ilds_ingestdigest/scripts/garage_sync.py

# ec2_sqs_kpi_poller.sh - Use bash
sed -i '1s|.*|#!/bin/bash|' /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh
chmod +x /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh

# kpi_aggregator.py - Use venv Python
sed -i '1s|.*|#!/opt/ilds_ingestdigest/kpi_data/bin/python3|' /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
chmod +x /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
```

### 2.3 Update Paths in garage_sync.py
```bash
sed -i "s|LOCAL_DOWNLOAD_DIR = \"./data/incoming_csvs\"|LOCAL_DOWNLOAD_DIR = \"/opt/ilds_ingestdigest/data/incoming_csvs\"|" /opt/ilds_ingestdigest/scripts/garage_sync.py
sed -i "s|self.window_dir = Path(\"./data/kpi_reports/windows\")|self.window_dir = Path(\"/opt/ilds_ingestdigest/data/kpi_reports/windows\")|" /opt/ilds_ingestdigest/scripts/garage_sync.py
```

---

---

## ▶️ **3. Start the Pipeline**

### 3.1 Start Garage Sync (Garage → AWS S3)
```bash
cd /opt/ilds_ingestdigest
pkill -f garage_sync.py
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
```

### 3.2 Start SQS Poller (AWS SQS → KPI Reports)
```bash
pkill -f ec2_sqs_kpi_poller.sh
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &
```

### 3.3 Configure KPI Aggregator (Cron Job)
```bash
# Edit crontab
crontab -e
```
Add:
```cron
# Aggregate 6-min window reports to hourly/daily every hour
0 * * * * /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py >> /opt/ilds_ingestdigest/logs/aggregator.log 2>&1
```

Verify:
```bash
crontab -l
```

---

---

## 🧪 **4. Test the Pipeline**

### 4.1 Upload Test CSV to Garage S3
```bash
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
print('✓ Uploaded to Garage S3: BFA8/$FILENAME')
"
```

### 4.2 Verify Upload
```bash
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "
import boto3
from botocore.config import Config
from config.aws_config import *
s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL,
    aws_access_key_id=GARAGE_ACCESS_KEY_ID,
    aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY,
    region_name=GARAGE_REGION,
    config=Config(s3={'addressing_style': 'path'}))
print('Garage bucket contents:')
for obj in s3.list_objects_v2(Bucket=GARAGE_S3_BUCKET).get('Contents', []):
    print(f'  {obj[\"Key\"]}')
"
```

### 4.3 Monitor Pipeline

**Garage Sync Log:**
```bash
tail -f /opt/ilds_ingestdigest/logs/garage_sync.log
```
*Expected:* `⬇ Downloading BFA8/test_...csv` → `✓ Schema valid` → `⬆ Uploaded to AWS S3`

**SQS Poller Log:**
```bash
tail -f /opt/ilds_ingestdigest/logs/sqs_poller.log
```
*Expected:* `Processing message` → `KPI report generated`

---

---

## ✅ **5. Verify KPI Reports**

### 5.1 After 6 Minutes
```bash
ls -la /opt/ilds_ingestdigest/data/kpi_reports/windows/
ls -la /opt/ilds_ingestdigest/data/kpi_reports/hourly/
ls -la /opt/ilds_ingestdigest/data/kpi_reports/daily/
```

### 5.2 Manually Run Aggregator
```bash
/opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
```

### 5.3 View a Report
```bash
cat /opt/ilds_ingestdigest/data/kpi_reports/windows/*.json | python3 -m json.tool | head -50
```

---

---

## 🛠️ **6. Troubleshooting**

### ❌ Issue: "No module named 'boto3'"
**Cause:** Script using system Python instead of venv
**Fix:**
```bash
# Verify venv has boto3
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "import boto3; print(boto3.__version__)"

# Ensure shebangs point to venv Python
head -1 /opt/ilds_ingestdigest/scripts/garage_sync.py
# Should be: #!/opt/ilds_ingestdigest/kpi_data/bin/python3
```

### ❌ Issue: "Connection timeout to Garage"
**Cause:** Tailscale VPN not connected
**Fix:**
```bash
tailscale status
tailscale up --reset
```

### ❌ Issue: "No new files" but files exist in Garage
**Cause:** Wrong working directory or relative paths
**Fix:**
```bash
# Use absolute paths
sed -i "s|LOCAL_DOWNLOAD_DIR = \"./data/incoming_csvs\"|LOCAL_DOWNLOAD_DIR = \"/opt/ilds_ingestdigest/data/incoming_csvs\"|" /opt/ilds_ingestdigest/scripts/garage_sync.py
sed -i "s|self.window_dir = Path(\"./data/kpi_reports/windows\")|self.window_dir = Path(\"/opt/ilds_ingestdigest/data/kpi_reports/windows\")|" /opt/ilds_ingestdigest/scripts/garage_sync.py

# Restart from correct directory
cd /opt/ilds_ingestdigest
pkill -f garage_sync.py
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
```

### ❌ Issue: "SyntaxError: invalid syntax" in sqs_poller
**Cause:** Running shell script with Python
**Fix:**
```bash
# Ensure shebang is bash, not python
sed -i '1s|.*|#!/bin/bash|' /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh
chmod +x /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh

# Restart
pkill -f ec2_sqs_kpi_poller.sh
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &
```

### ❌ Issue: Upload not reaching Garage
**Cause:** Shell variable expansion in Python -c
**Fix:** Use consistent filename variable
```bash
TIMESTAMP=$(date +%s)
FILENAME="test_bfa8_$TIMESTAMP.csv"
echo "timestamp,sensor_id,value,$(date -u +%Y-%m-%dT%H:%M:%SZ),BFA8,100" > /tmp/$FILENAME
/opt/ilds_ingestdigest/kpi_data/bin/python3 -c "import boto3; from botocore.config import Config; from config.aws_config import *; s3 = boto3.client('s3', endpoint_url=GARAGE_ENDPOINT_URL, aws_access_key_id=GARAGE_ACCESS_KEY_ID, aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY, region_name=GARAGE_REGION, config=Config(s3={'addressing_style': 'path'})); s3.upload_file('/tmp/$FILENAME', GARAGE_S3_BUCKET, 'BFA8/$FILENAME')"
```

---

---

## 📊 **7. Pipeline Flow Diagram**
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
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   Garage S3          │     │   AWS S3             │     │   AWS SQS            │
│   (100.78.2.20:3900) │────▶│   (453914763342)    │────▶│   (SNS trigger)     │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
▲                                                                   │
│                                                                   ▼
┌───────┴───────┐     ┌─────────────────────────────────────────────────────────┐
│ garage_sync.py │     │                                            ec2_sqs_kpi_poller.sh │
│  - Polls Garage│     │  - Polls SQS                          - Generates 6-min KPI │
│  - Downloads CSV│     │  - Processes messages                  window reports     │
│  - Uploads to AWS│     └─────────────────────────────────────────────────────────┘
│  - Triggers SNS  │                                                     │
└─────────────────┘                                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                              kpi_aggregator.py (cron)                   │
│  - Aggregates 6-min → hourly → daily reports                           │
└─────────────────────────────────────────────────────────────────────┘
│              │              │
▼              ▼              ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  windows/        │ │  hourly/         │ │  daily/          │
│  *.json         │ │  *.json         │ │  *.json          │
└─────────────────┘ └─────────────────┘ └─────────────────┘


---

---

## 📝 **8. Key Files Summary**

| File | Purpose | Location |
|------|---------|----------|
| `garage_sync.py` | Garage → AWS S3 sync with KPI tracking | `/opt/ilds_ingestdigest/scripts/` |
| `ec2_sqs_kpi_poller.sh` | SQS message processor | `/opt/ilds_ingestdigest/scripts/` |
| `kpi_aggregator.py` | 6-min → hourly → daily aggregation | `/opt/ilds_ingestdigest/scripts/` |
| `aws_config.py` | AWS/Garage credentials | `/opt/ilds_ingestdigest/config/` |
| `.env` | Environment variables | `/opt/ilds_ingestdigest/.env` |
| KPI Reports | Generated JSON reports | `/opt/ilds_ingestdigest/data/kpi_reports/{windows,hourly,daily}/` |
| Logs | Service logs | `/opt/ilds_ingestdigest/logs/` |

---

---

## 🎯 **9. Expected KPI Report Structure**

### 6-Minute Window Report (`windows/*.json`)
```json
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
