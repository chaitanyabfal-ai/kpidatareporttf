# ILDS S3 + Garage Uploader Project

Complete data pipeline for ingesting sensor data from Garage (via Tailscale VPN), uploading to AWS S3, and processing with EC2-based KPI metrics.

## Architecture

```
Garage S3 (Tailscale VPN)
    ↓
garage_sync.py (continuous polling)
    ↓
AWS S3 (raw-sensor-data/)
    ↓
S3 Event → SNS Topic → SQS Queue
    ↓
EC2 Poller (KPI processing)
    ↓
    ├── data/kpi_reports/ec2_queue_kpi_latest.json
    ├── data/kpi_reports/windows/*.json
    └── KPI aggregator → hourly/daily reports → Streamlit dashboard
```

## Quick Start

### 1. Get Garage Credentials
Access Garage at `http://100.78.2.20:3900` (via Tailscale VPN) and create S3 API credentials.

### 2. Update .env
```bash
GARAGE_ACCESS_KEY_ID=your_key_here
GARAGE_SECRET_ACCESS_KEY=your_secret_here
```

### 3. Test Connection
```bash
./scripts/test_garage_integration.sh
```

### 4. Start Sync
```bash
python3 scripts/garage_sync.py          # Continuous
# OR
python3 scripts/garage_sync.py --once   # One-time test
```

See **GARAGE_INTEGRATION_GUIDE.md** for detailed setup.

## KPI Dashboard

The repository includes a Streamlit dashboard for the generated KPI reports.
It reads `data/kpi_reports/{daily,hourly,windows}` and updates when the report
files are refreshed.

```bash
python3 -m pip install -r requirements.txt
streamlit run dashboard/app.py
```

Open the local URL printed by Streamlit, then choose the report resolution in
the upper-right control. The dashboard supports empty report directories and
will show an empty state until the sync or aggregator has produced reports.

For the cloud deployment, the dashboard runs as a localhost-only systemd
service on EC2. Use SSM port forwarding to open it locally without exposing
Streamlit to the public internet:

```bash
aws ssm start-session \
    --target <instance-id> \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["8501"],"localPortNumber":["8501"]}'
```

Then open `http://127.0.0.1:8501`.

## Components

- **garage_sync.py** — Downloads CSVs from Garage S3 (via Tailscale), uploads to AWS S3
- **s3_uploader.py** — Validates schema, uploads to AWS S3 with correct prefix
- **ec2_sqs_kpi_poller.sh** — EC2 worker that polls SQS, computes KPI metrics
- **kpi_aggregator.py** — Converts six-minute reports into hourly and daily views
- **dashboard/app.py** — Streamlit dashboard for live SQS, window, hourly, and daily reports
- **aws_config.py** — Centralized configuration for AWS and Garage endpoints
- **test_garage_integration.sh** — Verify Tailscale VPN and credentials

## Folder layout

```text
ilds_s3_garage_uploader_project/
├── README.md
├── RUNBOOK.md
├── .env.example
├── requirements.txt
├── config/
│   └── aws_config.py
├── scripts/
│   ├── s3_uploader.py
│   ├── garage_sync.py
│   └── aws_s3_setup_check.py
├── data/
│   ├── incoming_csvs/
│   └── logs/
├── tests/
│   └── test_uploader_contract.py
└── notes/
    └── aws_setup_notes.md
```

## Runbook

See [RUNBOOK.md](RUNBOOK.md) for the AWS CLI provisioning steps and the local project setup workflow.
ago