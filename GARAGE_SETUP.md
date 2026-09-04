# Garage S3 Integration Setup

## Prerequisites

✅ **Tailscale VPN Connected** (verified working)
- Garage endpoint reachable at `http://100.78.2.20:3900`

## Step 1: Get Garage S3 Credentials

You need to obtain your Garage S3 credentials. These are typically:
- **Access Key ID** — identifier for your Garage account
- **Secret Access Key** — password for Garage S3 access
- **Bucket Name** — where your sensor data is stored (default: `data`)

### Where to get credentials:
1. Log into Garage admin panel at `http://100.78.2.20:3900` (via Tailscale VPN)
2. Navigate to **Users** or **S3 Credentials**
3. Create or retrieve your S3 access key and secret
4. Note your bucket name (usually `data` for default setup)

---

## Step 2: Configure .env

Update your `.env` file with the Garage credentials:

```bash
# Current placeholders in .env:
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=YOUR_GARAGE_KEY           # ← Replace with actual key
GARAGE_SECRET_ACCESS_KEY=YOUR_GARAGE_SECRET    # ← Replace with actual secret
```

**Example:**
```bash
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=GK123abc456xyz...
GARAGE_SECRET_ACCESS_KEY=7abcd1ef2ghij3klmno4pqr5stuvwx...
```

---

## Step 3: Test Connection

```bash
./scripts/test_garage_integration.sh
```

Expected output:
```
✓ Garage endpoint IP is reachable: 100.78.2.20
✓ Credentials found
✓ Connected to Garage S3!
✓ Available buckets: ['data']
✓ Bucket 'data': N objects, M CSV files
================================================
✓ GARAGE INTEGRATION TEST PASSED
```

---

## Step 4: Start Garage Sync

The garage sync script automatically:
1. Connects to Garage S3 via Tailscale VPN
2. Downloads CSV files from Garage bucket
3. Validates CSV schema (requires `Timestamp` and `Voltage` or `Pressure`)
4. Uploads to AWS S3 bucket
5. Triggers SNS → SQS → EC2 KPI processing pipeline

**Run continuously (recommended):**
```bash
python3 scripts/garage_sync.py
```

**Or run once:**
```bash
python3 scripts/garage_sync.py --once
```

---

## Data Flow

```
Garage S3 (Tailscale VPN)
    ↓
Download CSV
    ↓
Validate Schema
    ↓
AWS S3 (raw-sensor-data/ prefix)
    ↓
S3 ObjectCreated Event
    ↓
SNS Topic
    ↓
SQS Queue
    ↓
EC2 Poller
    ↓
Compute KPI Metrics
    ↓
JSON Report (data/kpi_reports/ec2_queue_kpi_latest.json)
```

---

## Troubleshooting

### "Cannot reach Garage endpoint IP"
- Check Tailscale VPN status: `tailscale status`
- Verify Tailscale is connected and authenticated
- Try ping: `ping 100.78.2.20`

### "GARAGE_ACCESS_KEY_ID is not set"
- Update `.env` with actual credentials from Garage
- Verify no trailing spaces in `.env`

### "Failed to connect: InvalidAccessKeyId"
- Check credentials are correct in `.env`
- Verify credentials haven't been revoked in Garage

### "Bucket 'data' not found"
- Verify bucket name in `.env` matches Garage
- List available buckets in Garage admin panel

---

## Next Steps

1. Provide Garage credentials
2. Run `./scripts/test_garage_integration.sh`
3. Start `python3 scripts/garage_sync.py` in a terminal or systemd service
4. Upload test CSV to Garage S3 bucket
5. Verify file appears in AWS S3, SQS queue, and KPI report

