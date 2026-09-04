# 🛑 ILDS S3 Garage Uploader - Complete Shutdown Runbook
**Safe Stop Procedure for All Components**

---

---

## ⚠️ **IMPORTANT: READ FIRST**
- **Non-destructive steps** (1-5) stop all processes but preserve data/config
- **Destructive steps** (6-8) remove infrastructure and files (BLAST RADIUS - requires confirmation)
- Services run as `nohup` background processes - they survive SSH logout
- **Tailscale must remain active** if you plan to restart later (Garage S3 access)

---

---

## 🟡 **PART 1: GRACEFUL SHUTDOWN (Non-Destructive)**

### Step 1: Stop All Application Processes
```bash
# Connect to EC2
ssh -i ~/.ssh/id_rsa.pem ec2-user@13.232.79.9

# Stop garage_sync.py
pkill -f garage_sync.py

# Stop ec2_sqs_kpi_poller.sh
pkill -f ec2_sqs_kpi_poller.sh

# Stop any Python processes related to the project
pkill -f "kpi_aggregator.py"
pkill -f "python3.*ilds"
```

**Verify processes stopped:**
```bash
ps aux | grep -E 'garage_sync|sqs_poller|kpi_aggregator' | grep -v grep
# Should return NO results
```

---

### Step 2: Remove Cron Jobs
```bash
# Remove KPI aggregator cron job
crontab -e
```
Delete the line:
```cron
0 * * * * /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py >> /opt/ilds_ingestdigest/logs/aggregator.log 2>&1
```
Save and exit. Verify:
```bash
crontab -l
# Should be empty or only contain other jobs
```

---

### Step 3: Stop Tailscale (Optional)
> **⚠️ WARNING:** Only stop Tailscale if you won't need Garage S3 access. You'll need to re-authenticate later.

```bash
sudo systemctl stop tailscaled
sudo systemctl disable tailscaled
```

**Verify:**
```bash
tailscale status
# Should show "Not connected" or error
```

---

### Step 4: Backup Important Data (Recommended)
```bash
# Create backup directory
mkdir -p ~/ilds_backup_$(date +%Y%m%d)

# Backup KPI reports
cp -r /opt/ilds_ingestdigest/data/kpi_reports ~/ilds_backup_$(date +%Y%m%d)/

# Backup logs (last 7 days)
find /opt/ilds_ingestdigest/logs -name "*.log" -mtime -7 -exec cp {} ~/ilds_backup_$(date +%Y%m%d)/logs/ \;

# Backup configuration
cp /opt/ilds_ingestdigest/.env ~/ilds_backup_$(date +%Y%m%d)/
cp /opt/ilds_ingestdigest/scripts/*.py ~/ilds_backup_$(date +%Y%m%d)/scripts/
cp /opt/ilds_ingestdigest/scripts/*.sh ~/ilds_backup_$(date +%Y%m%d)/scripts/

# Create tar archive
cd ~
tar -czvf ilds_backup_$(date +%Y%m%d).tar.gz ilds_backup_$(date +%Y%m%d)
```

---

### Step 5: Verify Shutdown
```bash
# Check running processes
echo "=== Running Processes ==="
ps aux | grep -E 'garage_sync|sqs_poller|kpi_aggregator|python3' | grep -v grep

# Check cron
echo -e "\n=== Cron Jobs ==="
crontab -l

# Check Tailscale
echo -e "\n=== Tailscale Status ==="
tailscale status 2>&1 || echo "Tailscale not installed/running"

# Check logs (no new entries)
echo -e "\n=== Log Files (last 5 lines each) ==="
for log in /opt/ilds_ingestdigest/logs/*.log; do
  echo "--- $log ---"
  tail -n 5 "$log" 2>/dev/null || echo "Not found"
done

# Check incoming files (should stop growing)
echo -e "\n=== Incoming CSVs ==="
ls -la /opt/ilds_ingestdigest/data/incoming_csvs/ 2>/dev/null || echo "Directory not found"

echo -e "\n=== KPI Reports ==="
ls -la /opt/ilds_ingestdigest/data/kpi_reports/windows/ 2>/dev/null || echo "Directory not found"
```

**Expected output:**
- No processes running
- No cron jobs
- Tailscale stopped (if you chose to stop it)
- Static log files (no new entries)
- No new files appearing in `incoming_csvs/`

---

---

## 🔴 **PART 2: DESTRUCTIVE SHUTDOWN (BLAST RADIUS - Requires Confirmation)**

> **⚠️ WARNING:** These steps are **irreversible**. Only proceed if you want to completely remove all infrastructure and data.

---

### Step 6: Destroy Terraform Infrastructure
> **BLAST RADIUS:** This will **delete all AWS resources** (EC2, S3, SQS, SNS, IAM roles). The EC2 instance will be terminated.

```bash
# On your LOCAL machine (not EC2)
cd ~/kpidatareporttf/terraform

# Preview what will be destroyed
terraform plan -destroy

# If you confirm, execute:
terraform destroy -auto-approve
```

**Verify AWS resources are gone:**
```bash
# Check EC2
aws ec2 describe-instances --filters "Name=tag:Name,Values=ilds-sensor-data-ec2"

# Check S3
aws s3 ls | grep ilds

# Check SQS
aws sqs list-queues | grep ilds
```

---

### Step 7: Remove Project Files from EC2
> **BLAST RADIUS:** This deletes all project files from the EC2 instance.

```bash
# On EC2
sudo rm -rf /opt/ilds_ingestdigest
```

**Verify:**
```bash
ls -la /opt/ilds_ingestdigest 2>&1
# Should show "No such file or directory"
```

---

### Step 8: Remove Tailscale (If No Longer Needed)
> **BLAST RADIUS:** Removes Tailscale from the system.

```bash
sudo systemctl stop tailscaled
sudo systemctl disable tailscaled
sudo dnf remove -y tailscale
sudo rm -rf /var/lib/tailscale
sudo rm -rf /etc/default/tailscaled
```

**Verify:**
```bash
which tailscale 2>&1
# Should show "not found" or similar
```

---

---

## ✅ **SHUTDOWN CHECKLIST**

| # | Task | Command | Status |
|---|------|---------|--------|
| 1 | Stop garage_sync.py | `pkill -f garage_sync.py` | ⬜ |
| 2 | Stop ec2_sqs_kpi_poller.sh | `pkill -f ec2_sqs_kpi_poller.sh` | ⬜ |
| 3 | Stop kpi_aggregator processes | `pkill -f kpi_aggregator` | ⬜ |
| 4 | Remove cron job | `crontab -e` (delete line) | ⬜ |
| 5 | Verify no processes | `ps aux \| grep -E 'garage_sync\|sqs_poller\|kpi_aggregator'` | ⬜ |
| 6 | Stop Tailscale (optional) | `sudo systemctl stop tailscaled` | ⬜ |
| 7 | Backup data | `cp -r /opt/ilds_ingestdigest/data ~/backup` | ⬜ |
| 8 | Destroy Terraform (BLAST RADIUS) | `terraform destroy -auto-approve` | ⬜ |
| 9 | Remove project files (BLAST RADIUS) | `sudo rm -rf /opt/ilds_ingestdigest` | ⬜ |
| 10 | Remove Tailscale (BLAST RADIUS) | `sudo dnf remove -y tailscale` | ⬜ |

---

---

## 🔄 **RESTARTING THE PROJECT**

If you only did **Part 1 (Graceful Shutdown)**, restart with:

```bash
# SSH to EC2
ssh -i ~/.ssh/id_rsa.pem ec2-user@13.232.79.9

# Start Tailscale (if stopped)
sudo systemctl start tailscaled
tailscale up

# Start services
cd /opt/ilds_ingestdigest
nohup /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/garage_sync.py --interval 30 > /opt/ilds_ingestdigest/logs/garage_sync.log 2>&1 &
nohup /opt/ilds_ingestdigest/scripts/ec2_sqs_kpi_poller.sh > /opt/ilds_ingestdigest/logs/sqs_poller.log 2>&1 &

# Re-add cron job
(crontab -l 2>/dev/null; echo "0 * * * * /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py >> /opt/ilds_ingestdigest/logs/aggregator.log 2>&1") | crontab -
```

---

---

## 📋 **QUICK STOP COMMANDS (One-Liner)**

```bash
# Non-destructive: Stop all processes and cron
pkill -f garage_sync.py && pkill -f ec2_sqs_kpi_poller.sh && pkill -f kpi_aggregator && crontab -e

# Full destructive shutdown (BLAST RADIUS - requires manual confirmation)
pkill -f garage_sync.py && pkill -f ec2_sqs_kpi_poller.sh && pkill -f kpi_aggregator && \
crontab -r && \
sudo systemctl stop tailscaled && \
sudo rm -rf /opt/ilds_ingestdigest && \
cd ~/kpidatareporttf/terraform && terraform destroy -auto-approve
```

---

---

## 🚨 **EMERGENCY STOP**

If something is going wrong and you need to stop everything **immediately**:

```bash
# Force kill ALL Python processes (may affect other apps)
pkill -9 -f python3

# Stop all background jobs
pkill -9 -f nohup

# Stop Tailscale
sudo systemctl stop tailscaled

# Disable network (last resort)
sudo ifconfig eth0 down
```

> **⚠️ WARNING:** Emergency stop may cause data corruption. Use only if absolutely necessary.

---

---
