# Garage Integration — Quick Reference

## 1. Get Credentials from Garage
- Access Garage admin: `http://100.78.2.20:3900` (via Tailscale VPN)
- Get S3 Access Key ID and Secret Key
- Note bucket name (usually `data`)

## 2. Update .env
```bash
GARAGE_ACCESS_KEY_ID=GKXXXXXXXXXXXXXXXX
GARAGE_SECRET_ACCESS_KEY=your_secret_here
GARAGE_S3_BUCKET=data
```

## 3. Test Connection
```bash
./scripts/test_garage_integration.sh
```

## 4. Start Garage Sync

**Once (test):**
```bash
python3 scripts/garage_sync.py --once
```

**Continuous (production):**
```bash
# Foreground
python3 scripts/garage_sync.py

# Background
nohup python3 scripts/garage_sync.py > logs/garage_sync.log 2>&1 &

# Systemd (recommended)
sudo cp garage-sync.service /etc/systemd/system/
sudo systemctl start garage-sync
sudo systemctl enable garage-sync
```

## 5. Monitor Pipeline

**Garage → AWS S3:**
```bash
ls data/incoming_csvs/
aws s3 ls s3://453914763342-ilds-sensor-data/raw-sensor-data/ --region ap-south-1
```

**SQS Queue:**
```bash
aws sqs get-queue-attributes --queue-url "..." --attribute-names ApproximateNumberOfMessages --region ap-south-1
```

**EC2 KPI Report:**
```bash
ssh -i ilds-key-1787743292.pem ubuntu@<EC2_IP>
cat ~/ilds_project/data/kpi_reports/ec2_queue_kpi_latest.json
```

## Data Flow
```
Garage S3 (Tailscale VPN)
  ↓
garage_sync.py (5s polling)
  ↓
AWS S3 (raw-sensor-data/)
  ↓
S3 → SNS → SQS
  ↓
EC2 Poller
  ↓
KPI JSON Report
```

---

**Full documentation:** See `GARAGE_INTEGRATION_GUIDE.md`
