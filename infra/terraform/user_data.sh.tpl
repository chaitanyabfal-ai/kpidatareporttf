#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y git python3 python3-pip python3-devel gcc

id -u ${deploy_user} &>/dev/null || useradd -m ${deploy_user}

su - ${deploy_user} -c "
  set -e
  cd /home/${deploy_user}
  if [ ! -d ilds_s3_garage_uploader_project ]; then
    git clone ${repo_url} ilds_s3_garage_uploader_project
  fi
  cd ilds_s3_garage_uploader_project
  python3 -m venv kpi_data
  source kpi_data/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
  mkdir -p data/incoming_csvs data/garage_kpi_downloads data/kpi_reports data/logs

  cat > .env <<'ENVEOF'
AWS_REGION=${aws_region}
S3_BUCKET=${bucket_name}
SQS_QUEUE_URL=${queue_url}
WATCH_DIRECTORY=./data/incoming_csvs
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=REPLACE_ME
GARAGE_SECRET_ACCESS_KEY=REPLACE_ME
ENVEOF
"
# GARAGE_* are placeholders — this instance has no Tailscale VPN route to
# Garage by default anyway. Set real values by editing .env after
# connecting (SSH or SSM), then restart the systemd services below.
# Never bake real secrets into user-data: it's readable by anyone who can
# call ec2:DescribeInstanceAttribute or reach the instance metadata service.

# Install and enable the systemd services shipped in the repo.
cp /home/${deploy_user}/ilds_s3_garage_uploader_project/systemd/garage-sync.service /etc/systemd/system/
cp /home/${deploy_user}/ilds_s3_garage_uploader_project/systemd/ec2-sqs-poller.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now garage-sync
systemctl enable --now ec2-sqs-poller
