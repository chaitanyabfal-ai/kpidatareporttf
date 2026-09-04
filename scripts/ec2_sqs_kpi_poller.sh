#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Load local env if present.
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${PROJECT_ROOT}/.env"
  set +a
fi

AWS_REGION="${AWS_REGION:-ap-south-1}"
QUEUE_URL="${QUEUE_URL:-${SQS_QUEUE_URL:-}}"
BUCKET_NAME="${BUCKET_NAME:-${S3_BUCKET:-}}"
WORK_DIR="${WORK_DIR:-${PROJECT_ROOT}/data/ec2_queue_kpi_worker}"
REPORT_DIR="${REPORT_DIR:-${PROJECT_ROOT}/data/kpi_reports}"

if [[ -z "${QUEUE_URL}" ]]; then
  echo "QUEUE_URL is not set. Export SQS_QUEUE_URL or pass it in .env before running this worker." >&2
  exit 1
fi

mkdir -p "${WORK_DIR}" "${REPORT_DIR}"

python3 << 'PY'
import json
import os
import sys
import time
import traceback
from pathlib import Path
from urllib.parse import unquote_plus

import boto3
import pandas as pd
from botocore.exceptions import ClientError

# Load .env if present
env_file = Path('.env')
if env_file.exists():
    with open(env_file) as f:
        for line in f:
            if '=' in line and not line.startswith('#'):
                key, val = line.strip().split('=', 1)
                os.environ.setdefault(key, val)

queue_url = os.environ.get('QUEUE_URL') or os.environ.get('SQS_QUEUE_URL')
aws_region = os.environ.get('AWS_REGION', 'ap-south-1')
bucket_name = os.environ.get('BUCKET_NAME') or os.environ.get('S3_BUCKET')
work_dir = os.environ.get('WORK_DIR', './data/ec2_queue_kpi_worker')
report_dir = os.environ.get('REPORT_DIR', './data/kpi_reports')

sqs = boto3.client("sqs", region_name=aws_region)
s3 = boto3.client("s3", region_name=aws_region)

work_dir = Path(work_dir)
report_dir = Path(report_dir)
work_dir.mkdir(parents=True, exist_ok=True)
report_dir.mkdir(parents=True, exist_ok=True)


def parse_notifications(body: str):
    try:
        payload = json.loads(body)
        message = payload.get("Message")
        if message:
            payload = json.loads(message)
        records = payload.get("Records", [])
    except Exception:
        return []

    notifications = []
    for record in records:
        s3_info = record.get("s3")
        if not s3_info:
            continue
        bucket = s3_info.get("bucket", {}).get("name")
        key = s3_info.get("object", {}).get("key")
        if bucket and key:
            notifications.append((bucket, unquote_plus(key)))
    return notifications


def compute_file_metrics(csv_path: Path):
    df = pd.read_csv(csv_path)
    results = {
        "file": csv_path.name,
        "rows": int(len(df)),
        "columns": sorted(df.columns.tolist()),
        "mean_voltage": None,
        "mean_pressure": None,
        "min_voltage": None,
        "max_voltage": None,
        "min_pressure": None,
        "max_pressure": None,
    }

    if "Voltage" in df.columns:
        voltage = pd.to_numeric(df["Voltage"], errors="coerce").dropna()
        if not voltage.empty:
            results["mean_voltage"] = float(voltage.mean())
            results["min_voltage"] = float(voltage.min())
            results["max_voltage"] = float(voltage.max())

    if "Pressure" in df.columns:
        pressure = pd.to_numeric(df["Pressure"], errors="coerce").dropna()
        if not pressure.empty:
            results["mean_pressure"] = float(pressure.mean())
            results["min_pressure"] = float(pressure.min())
            results["max_pressure"] = float(pressure.max())

    return results


def emit_report(summary):
    report_path = report_dir / "ec2_queue_kpi_latest.json"
    report_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)


def log_failed_message(message_id: str, body: str, error: str):
    """Persist messages we couldn't process instead of silently dropping
    them — lets you inspect/replay later without crashing the service."""
    failed_dir = report_dir / "failed_messages"
    failed_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "message_id": message_id,
        "body": body,
        "error": error,
        "failed_at": int(time.time()),
    }
    (failed_dir / f"{message_id}.json").write_text(
        json.dumps(record, indent=2), encoding="utf-8"
    )


print(f"[POLLER] Starting. queue={queue_url} bucket={bucket_name}", flush=True)

seen = set()
while True:
    try:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=20,
            AttributeNames=["All"],
            MessageAttributeNames=["All"],
        )
    except ClientError as ce:
        print(f"[POLLER] receive_message failed: {ce}. Retrying in 10s.", flush=True)
        time.sleep(10)
        continue

    messages = response.get("Messages", [])
    if not messages:
        continue

    batch_summary = {
        "processed_at": int(time.time()),
        "queue_url": queue_url,
        "bucket": bucket_name,
        "files_processed": [],
        "total_files": 0,
    }

    for message in messages:
        message_id = message.get("MessageId", "unknown")
        body = message.get("Body", "")
        receipt_handle = message["ReceiptHandle"]

        # Every message gets a delete attempt at the end of this block,
        # success or failure — a message we can't process should not stay
        # in the queue forever and crash-loop the whole service.
        try:
            notifications = parse_notifications(body)
            if not notifications:
                continue

            for bucket, key in notifications:
                if bucket_name and bucket != bucket_name:
                    print(f"[POLLER] Skipping non-target bucket {bucket} for {key}", flush=True)
                    continue

                if key in seen:
                    print(f"[POLLER] Skipping already processed key {key}", flush=True)
                    continue

                try:
                    local_path = work_dir / Path(key).name
                    s3.download_file(bucket, key, str(local_path))
                    metrics = compute_file_metrics(local_path)
                    seen.add(key)
                    batch_summary["files_processed"].append({"bucket": bucket, "key": key, **metrics})
                    batch_summary["total_files"] += 1
                    print(f"[POLLER] Processed {key} from {bucket}: {metrics}", flush=True)
                except ClientError as ce:
                    # e.g. object doesn't exist (404), no S3 permission, etc.
                    # Log and move on to the next notification instead of
                    # crashing the whole process on one bad key.
                    err = f"S3 error for {bucket}/{key}: {ce}"
                    print(f"[POLLER] ✗ {err}", flush=True)
                    log_failed_message(message_id, body, err)
                except Exception as exc:
                    err = f"Unexpected error for {bucket}/{key}: {exc}\n{traceback.format_exc()}"
                    print(f"[POLLER] ✗ {err}", flush=True)
                    log_failed_message(message_id, body, err)

        except Exception as exc:
            # Malformed message body, unexpected structure, etc.
            err = f"Failed to parse/handle message: {exc}\n{traceback.format_exc()}"
            print(f"[POLLER] ✗ {err}", flush=True)
            log_failed_message(message_id, body, err)

        finally:
            try:
                sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            except ClientError as ce:
                print(f"[POLLER] ✗ Failed to delete message {message_id}: {ce}", flush=True)

    if batch_summary["files_processed"]:
        emit_report(batch_summary)
PY
