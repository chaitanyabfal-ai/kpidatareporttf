# Garage Integration — Complete Setup Guide

This guide walks through integrating Garage S3 (accessible via Tailscale VPN) with your AWS cloud data processing pipeline.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    GARAGE S3 (Tailscale VPN)                    │
│              http://100.78.2.20:3900 (via VPN)                  │
│                                                                   │
│  CSV Files: BFA8_Batch*.csv, BFA3_Batch*.csv                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │ ⬇ garage_sync.py
                           │   (continuous polling)
                           │
┌──────────────────────────┴──────────────────────────────────────┐
│                      AWS S3 Bucket                              │
│           453914763342-ilds-sensor-data                         │
│                                                                   │
│  ├─ raw-sensor-data/  (CSV files trigger events)               │
│  ├─ processed/        (KPI results)                             │
│  └─ logs/                                                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │ ⬇ S3 ObjectCreated Event
                           │
┌──────────────────────────┴──────────────────────────────────────┐
│                    SNS Topic                                    │
│              ilds-s3-events (or timestamp-based)                │
└──────────────────────────┬──────────────────────────────────────┘
                           │ ⬇ SNS Publish
                           │
┌──────────────────────────┴──────────────────────────────────────┐
│                    SQS Queue                                    │
│              ilds_queue_1 (or timestamp-based)                  │
│                                                                   │
│  Message contains S3 bucket/key and event details               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ ⬇ SQS ReceiveMessage
                           │
┌──────────────────────────┴──────────────────────────────────────┐
│                  EC2 Instance (t3.micro)                        │
│                                                                   │
│  ┌─ ec2_sqs_kpi_poller.sh                                      │
│  │  1. Poll SQS queue                                           │
│  │  2. Download CSV from S3                                    │
│  │  3. Compute KPI metrics (mean/min/max)                      │
│  │  4. Save report to data/kpi_reports/                        │
│  └─                                                             │
│                                                                   │
│  Output: ec2_queue_kpi_latest.json                             │
└──────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

✅ **Tailscale VPN**
- Must be connected to reach Garage at 100.78.2.20
- Check status: `tailscale status`

✅ **AWS Account Access**
- Region: `ap-south-1`
- S3 bucket, SNS, SQS, EC2 already provisioned

✅ **Garage S3 Credentials**
- Access Key ID (from Garage admin)
- Secret Access Key (from Garage admin)
- Bucket name (usually `data`)

---

## Step 1: Get Garage Credentials

### Option A: Garage Admin Panel
1. Connect to Garage via Tailscale VPN
2. Navigate to `http://100.78.2.20:3900`
3. Log in with admin credentials
4. Go to **Users** or **S3 API Keys**
5. Create new S3 API key or note existing credentials
6. You'll get:
   - **Access Key ID**: `GKXXXXXXXXXXXXXXXXXXXXXXXX` or similar
   - **Secret Access Key**: Long base64 string

### Option B: Ask your Garage Administrator
- Provide them your use case (data ingestion from Garage to AWS)
- Request S3 API credentials for read access to the data bucket

---

## Step 2: Configure .env

Edit `.env` in the project root:

```bash
nano .env
```

Update these lines:

```bash
# Garage S3 Configuration
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data                                    # ← Check actual bucket name
GARAGE_ACCESS_KEY_ID=GKXXXXXXXXXXXXXXXXXXXXXXXX          # ← Your Access Key ID
GARAGE_SECRET_ACCESS_KEY=your_secret_key_here...         # ← Your Secret
```

**Save and exit** (`Ctrl+X`, then `Y`, then `Enter` in nano)

---

## Step 3: Verify Connectivity

Test Garage connection:

```bash
./scripts/test_garage_integration.sh
```

Expected output:
```
✓ Garage endpoint IP is reachable: 100.78.2.20
✓ Credentials found
✓ Connected to Garage S3!
✓ Available buckets: ['data']
✓ Bucket 'data': 5 objects, 2 CSV files
================================================
✓ GARAGE INTEGRATION TEST PASSED
```

---

## Step 4: Start Garage Sync

### Option A: One-Time Sync (for testing)

```bash
python3 scripts/garage_sync.py --once
```

Output:
```
============================================================
GARAGE S3 → AWS S3 SYNC
============================================================
Garage endpoint: http://100.78.2.20:3900
Garage bucket:   data
Local download:  ./data/incoming_csvs
Mode:            One-time
============================================================

[GARAGE] Running one-time sync...
[GARAGE] Listing objects in bucket 'data'...
[GARAGE] ⬇ Downloading BFA8_Batch001_2026-09-01.csv...
[GARAGE] ✓ Downloaded: BFA8_Batch001_2026-09-01.csv
[GARAGE] ✓ Schema valid
[GARAGE] ⬆ Uploaded to AWS S3
[GARAGE] Sync complete. Processed 1 new files.
```

### Option B: Continuous Sync (recommended for production)

**Terminal foreground:**
```bash
python3 scripts/garage_sync.py
```

**Background with nohup:**
```bash
nohup python3 scripts/garage_sync.py > logs/garage_sync.log 2>&1 &
```

**Background with systemd (recommended):**
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

## Step 5: Monitor Data Flow

### Check Garage Downloads
```bash
ls -lah data/incoming_csvs/
```

### Check AWS S3 Upload
```bash
aws s3 ls s3://453914763342-ilds-sensor-data/raw-sensor-data/ --region ap-south-1
```

### Check SQS Queue
```bash
aws sqs get-queue-attributes \
  --queue-url "https://sqs.ap-south-1.amazonaws.com/453914763342/ilds_queue_1" \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-south-1
```

### Check EC2 KPI Report
```bash
# SSH to EC2
ssh -i ilds-key-1787743292.pem ubuntu@<EC2_IP>
cd ~/ilds_project
cat data/kpi_reports/ec2_queue_kpi_latest.json
```

---

## Step 6: Run EC2 KPI Poller

On your local machine:

```bash
ssh -i ilds-key-1787743292.pem ubuntu@<EC2_IP>
cd ~/ilds_project

# Run poller (continuous, with debug output)
python3 scripts/ec2_sqs_kpi_poller_debug.py

# Or production mode (silent)
./scripts/ec2_sqs_kpi_poller.sh
```

---

## Data Flow Example

**Timeline of a CSV upload:**

```
1. 08:00:00 - CSV uploaded to Garage S3
               ↓
2. 08:00:05 - garage_sync.py polls Garage, finds new CSV
               ↓
3. 08:00:10 - CSV downloaded and validated
               ↓
4. 08:00:15 - CSV uploaded to AWS S3 (raw-sensor-data/)
               ↓
5. 08:00:20 - S3 ObjectCreated event triggers SNS
               ↓
6. 08:00:25 - Message in SQS queue
               ↓
7. 08:00:30 - EC2 poller receives message
               ↓
8. 08:00:35 - CSV downloaded from S3, KPI computed
               ↓
9. 08:00:40 - JSON report saved: ec2_queue_kpi_latest.json
               {
                 "file": "BFA8_Batch001.csv",
                 "mean_voltage": 120.5,
                 "mean_pressure": 98.2,
                 ...
               }
```

---

## CSV Schema Requirements

Garage CSV files must contain these columns:

```csv
Timestamp,Voltage,Pressure
2026-09-01T08:00:00Z,120.5,98.2
2026-09-01T08:01:00Z,121.3,97.9
2026-09-01T08:02:00Z,119.8,98.5
```

**Filename requirements:**
- Must start with `BFA8_` or `BFA3_` (sensor prefix)
- Should contain `Batch` followed by a number: `BFA8_Batch001_...csv`
- Uploaded to Garage `data` bucket

---

## Troubleshooting

### "Cannot reach Garage endpoint IP"
```bash
# Check Tailscale
tailscale status

# Try ping
ping 100.78.2.20

# Check DNS
dig 100.78.2.20
```

### "GARAGE_ACCESS_KEY_ID not configured"
- Verify `.env` has credentials (not `YOUR_GARAGE_KEY`)
- No spaces or special characters
- Restart sync after updating `.env`

### "InvalidAccessKeyId" error
- Confirm credentials are correct in Garage admin
- Check if credentials were revoked
- Generate new credentials if needed

### "Bucket 'data' not found"
- Verify bucket name in `.env` matches Garage
- List available buckets: check Garage admin panel

### "Schema validation failed"
- CSV must have `Timestamp` column
- CSV must have either `Voltage` or `Pressure` column
- No empty rows before headers
- Check `data/incoming_csvs/` for downloaded files

### SQS queue not receiving messages
- Verify S3 bucket notification is configured
- Check SNS topic policy
- Check SQS queue policy (must allow S3 principal)

### EC2 poller not processing messages
- Verify EC2 IAM role has SQS permissions
- Check `.env` has correct `SQS_QUEUE_URL`
- Run poller with debug: `python3 scripts/ec2_sqs_kpi_poller_debug.py`

---

## Production Checklist

- [ ] Garage credentials configured in `.env`
- [ ] Connectivity test passes: `./scripts/test_garage_integration.sh`
- [ ] Garage sync running: `systemctl status garage-sync`
- [ ] Test CSV uploaded to Garage, appears in AWS S3
- [ ] SQS queue receives message
- [ ] EC2 poller computes KPI metrics
- [ ] JSON report generated
- [ ] Monitor logs: `sudo journalctl -u garage-sync -f`
- [ ] Set up log rotation for `logs/garage_sync.log`

---

## Support

For issues or questions:
1. Check logs: `sudo journalctl -u garage-sync -f`
2. Verify Tailscale VPN: `tailscale status`
3. Test connectivity: `./scripts/test_garage_integration.sh`
4. Review this guide sections: Troubleshooting

