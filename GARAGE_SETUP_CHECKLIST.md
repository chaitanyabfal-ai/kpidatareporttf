# Garage Integration Setup Checklist

## Phase 1: Obtain Credentials
- [ ] Access Garage admin panel: `http://100.78.2.20:3900` (via Tailscale VPN)
- [ ] Navigate to Users/S3 API Keys section
- [ ] Note or create S3 credentials
- [ ] Confirm bucket name (usually `data`)
- [ ] Save credentials securely

**Credentials needed:**
```
GARAGE_ACCESS_KEY_ID = ________________
GARAGE_SECRET_ACCESS_KEY = ________________
GARAGE_S3_BUCKET = ________________
```

---

## Phase 2: Configure Environment
- [ ] Edit `.env` file: `nano .env`
- [ ] Set `GARAGE_ACCESS_KEY_ID` with actual key
- [ ] Set `GARAGE_SECRET_ACCESS_KEY` with actual secret
- [ ] Verify `GARAGE_S3_BUCKET` is correct
- [ ] Save file (Ctrl+X, Y, Enter)
- [ ] Verify changes: `grep GARAGE .env`

---

## Phase 3: Test Connectivity
- [ ] Run connectivity test: `./scripts/test_garage_integration.sh`
- [ ] Verify Tailscale VPN check passes (✓)
- [ ] Verify credentials check passes (✓)
- [ ] Verify S3 connection test passes (✓)
- [ ] See list of available buckets
- [ ] Confirm target bucket is accessible

---

## Phase 4: Perform Test Sync
- [ ] Run one-time sync: `python3 scripts/garage_sync.py --once`
- [ ] Watch for downloaded files in output
- [ ] Verify upload to AWS S3 succeeds
- [ ] Check AWS S3 bucket: 
  ```bash
  aws s3 ls s3://453914763342-ilds-sensor-data/raw-sensor-data/
  ```
- [ ] Confirm CSV files appear

---

## Phase 5: Verify Full Pipeline
- [ ] Check SQS queue received message:
  ```bash
  aws sqs get-queue-attributes \
    --queue-url "https://sqs.ap-south-1.amazonaws.com/453914763342/ilds_queue_1" \
    --attribute-names ApproximateNumberOfMessages \
    --region ap-south-1
  ```
- [ ] SSH to EC2: `ssh -i ilds-key-1787743292.pem ubuntu@<EC2_IP>`
- [ ] Run KPI poller: `python3 ~/ilds_project/scripts/ec2_sqs_kpi_poller_debug.py`
- [ ] Verify KPI JSON generated: `cat data/kpi_reports/ec2_queue_kpi_latest.json`
- [ ] Confirm metrics (mean_voltage, mean_pressure) are computed

---

## Phase 6: Start Production Sync

Choose ONE option:

### Option A: Foreground (for active monitoring)
- [ ] Run: `python3 scripts/garage_sync.py`
- [ ] Watch logs in real-time
- [ ] Press Ctrl+C to stop

### Option B: Background with nohup
- [ ] Run: `nohup python3 scripts/garage_sync.py > logs/garage_sync.log 2>&1 &`
- [ ] Check status: `ps aux | grep garage_sync`
- [ ] Monitor logs: `tail -f logs/garage_sync.log`

### Option C: Systemd (recommended for production)
- [ ] Copy service: `sudo cp garage-sync.service /etc/systemd/system/`
- [ ] Reload systemd: `sudo systemctl daemon-reload`
- [ ] Start service: `sudo systemctl start garage-sync`
- [ ] Enable auto-start: `sudo systemctl enable garage-sync`
- [ ] Check status: `sudo systemctl status garage-sync`
- [ ] View logs: `sudo journalctl -u garage-sync -f`

---

## Phase 7: Production Monitoring

### Daily Checks
- [ ] Sync service is running: `systemctl status garage-sync`
- [ ] No errors in logs: `sudo journalctl -u garage-sync --since today`
- [ ] Files being processed: Check `data/incoming_csvs/`
- [ ] S3 has new files: `aws s3 ls s3://453914763342-ilds-sensor-data/raw-sensor-data/ --recursive | wc -l`

### Weekly Checks
- [ ] Review log file size (set up rotation if needed)
- [ ] Verify KPI reports are being generated
- [ ] Check for any credential expiration notices
- [ ] Backup configuration if needed

### Monthly Checks
- [ ] Review data processing statistics
- [ ] Check for any changes needed in configuration
- [ ] Validate Garage credentials are still valid
- [ ] Review AWS costs and usage

---

## Troubleshooting Checklist

If something fails:

### Connectivity Issues
- [ ] Verify Tailscale VPN: `tailscale status`
- [ ] Test ping: `ping 100.78.2.20`
- [ ] Check DNS: `nslookup 100.78.2.20`
- [ ] Restart VPN if needed

### Credential Issues
- [ ] Verify credentials in `.env`: `grep GARAGE .env`
- [ ] Check for spaces/typos
- [ ] Verify credentials are still valid in Garage admin
- [ ] Try regenerating credentials in Garage if expired

### Sync Issues
- [ ] Check logs: `sudo journalctl -u garage-sync`
- [ ] Run test: `./scripts/test_garage_integration.sh`
- [ ] Test manually: `python3 scripts/garage_sync.py --once`
- [ ] Check if Garage bucket has files

### Pipeline Issues
- [ ] Verify S3 bucket exists: `aws s3 ls`
- [ ] Verify SQS queue: `aws sqs list-queues`
- [ ] Verify SNS topic: `aws sns list-topics`
- [ ] Check EC2 instance is running

---

## Quick Commands Reference

```bash
# Test connectivity
./scripts/test_garage_integration.sh

# Test sync (one-time)
python3 scripts/garage_sync.py --once

# Start sync (foreground)
python3 scripts/garage_sync.py

# Start sync (background)
nohup python3 scripts/garage_sync.py > logs/garage_sync.log 2>&1 &

# Check systemd status
sudo systemctl status garage-sync

# View logs
sudo journalctl -u garage-sync -f

# Check Tailscale
tailscale status

# List AWS S3
aws s3 ls s3://453914763342-ilds-sensor-data/raw-sensor-data/

# Check SQS
aws sqs get-queue-attributes --queue-url "https://sqs.ap-south-1.amazonaws.com/453914763342/ilds_queue_1" --attribute-names ApproximateNumberOfMessages --region ap-south-1

# SSH to EC2
ssh -i ilds-key-1787743292.pem ubuntu@<EC2_IP>

# Run KPI poller
python3 ~/ilds_project/scripts/ec2_sqs_kpi_poller_debug.py

# View KPI report
cat ~/ilds_project/data/kpi_reports/ec2_queue_kpi_latest.json
```

---

## Status Tracking

- [ ] **Phase 1** — Credentials obtained: _____________
- [ ] **Phase 2** — Environment configured: _____________
- [ ] **Phase 3** — Connectivity verified: _____________
- [ ] **Phase 4** — Test sync successful: _____________
- [ ] **Phase 5** — Full pipeline working: _____________
- [ ] **Phase 6** — Production sync started: _____________
- [ ] **Phase 7** — Monitoring in place: _____________

---

**Date Started:** _______________
**Date Completed:** _______________
**Notes:**
```
_________________________________________________________________

_________________________________________________________________

_________________________________________________________________
```

