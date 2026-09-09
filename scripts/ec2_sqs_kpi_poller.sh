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
WINDOW_DIR="${WINDOW_DIR:-${PROJECT_ROOT}/data/kpi_reports/windows}"

# Create directories
mkdir -p "${WORK_DIR}" "${REPORT_DIR}" "${WINDOW_DIR}"

# === KPI TRACKING ===
python3 << 'PY'
import json
import os
import sys
import time
import traceback
from pathlib import Path
from urllib.parse import unquote_plus
from datetime import datetime, timedelta
from collections import defaultdict

import boto3
import pandas as pd
from botocore.exceptions import ClientError
from scripts.reliability import summarize_timestamp_reliability

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
window_dir = os.environ.get('WINDOW_DIR', './data/kpi_reports/windows')

sqs = boto3.client("sqs", region_name=aws_region)
s3 = boto3.client("s3", region_name=aws_region)

work_dir = Path(work_dir)
report_dir = Path(report_dir)
window_dir = Path(window_dir)
work_dir.mkdir(parents=True, exist_ok=True)
report_dir.mkdir(parents=True, exist_ok=True)
window_dir.mkdir(parents=True, exist_ok=True)

# KPI Tracker for SQS processing
class SQSKPITracker:
    def __init__(self):
        self.window_stats = defaultdict(lambda: {
            "files_processed": 0,
            "by_sensor": defaultdict(int),
            "latencies_ms": [],
            "errors": [],
            "window_start": None,
            "window_end": None
        })
        self.last_processed = {}
        self.window_size_seconds = 360  # 6 minutes

    def get_6min_window(self):
        now = datetime.utcnow()
        base = now.replace(second=0, microsecond=0)
        window_start_minute = (base.minute // 6) * 6
        return base.replace(minute=window_start_minute)

    def get_window_key(self):
        window_start = self.get_6min_window()
        return window_start.strftime("%Y-%m-%dT%H:%M:00Z")

    def log_processing(self, bucket, key, sensor, success=True, latency_ms=None, error=None):
        window = self.get_window_key()
        start, end = self.get_window_range(window)

        if window not in self.window_stats:
            self.window_stats[window]["window_start"] = start.isoformat() + "Z"
            self.window_stats[window]["window_end"] = end.isoformat() + "Z"

        if success:
            self.window_stats[window]["files_processed"] += 1
            self.window_stats[window]["by_sensor"][sensor] += 1
            if latency_ms:
                self.window_stats[window]["latencies_ms"].append(latency_ms)
        else:
            self.window_stats[window]["errors"].append({
                "bucket": bucket,
                "key": key,
                "sensor": sensor,
                "error": str(error)
            })

        self.last_processed[key] = datetime.utcnow()

    def get_window_range(self, window_key=None):
        window_start = self.get_6min_window() if window_key is None else datetime.strptime(window_key, "%Y-%m-%dT%H:%M:00Z")
        return window_start, window_start + timedelta(seconds=self.window_size_seconds)

    def emit_window_report(self, window_key):
        """Generate and save KPI report for a 6-min window."""
        if window_key not in self.window_stats:
            return

        stats = self.window_stats[window_key]
        latencies = stats.get("latencies_ms", [])
        latencies.sort()
        n = len(latencies)

        report = {
            "report_id": f"sqs_kpi_{window_key}",
            "processed_at": int(time.time()),
            "window": {
                "key": window_key,
                "start": stats.get("window_start"),
                "end": stats.get("window_end"),
                "duration_seconds": self.window_size_seconds
            },
            "sqs_processing": {
                "files_processed": stats.get("files_processed", 0),
                "by_sensor": dict(stats.get("by_sensor", {})),
                "errors": stats.get("errors", []),
                "error_count": len(stats.get("errors", []))
            },
            "latency_ms": {
                "avg": round(sum(latencies) / n, 2) if n > 0 else 0,
                "p50": latencies[n//2] if n > 0 else 0,
                "p95": latencies[int(n*0.95)] if n > 0 else 0,
                "p99": latencies[int(n*0.99)] if n > 0 else 0,
                "min": latencies[0] if n > 0 else 0,
                "max": latencies[-1] if n > 0 else 0
            }
        }

        report_path = window_dir / f"sqs_{window_key}.json"
        report_path.write_text(json.dumps(report, indent=2))
        print(f"[SQS-KPI] Generated window report: {window_key}", flush=True)
        return report

    def emit_all_reports(self):
        """Emit reports for all completed windows."""
        now = datetime.utcnow()
        for window_key in list(self.window_stats.keys()):
            start, _ = self.get_window_range(window_key)
            if (now - start) >= timedelta(seconds=self.window_size_seconds):
                self.emit_window_report(window_key)
                del self.window_stats[window_key]

SQS_TRACKER = SQSKPITracker()

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

def infer_sensor_from_key(key: str) -> str:
    """Infer sensor from S3 key path."""
    if "BFA8" in key:
        return "BFA8"
    elif "BFA3" in key:
        return "BFA3"
    elif "BFA12" in key:
        return "BFA12"
    return "UNKNOWN"

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
        "timestamp_reliability": summarize_timestamp_reliability(df),
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

def emit_combined_report(summary):
    """Emit combined report for both garage sync and SQS processing."""
    report_path = report_dir / "ec2_queue_kpi_latest.json"
    report_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)

def log_failed_message(message_id: str, body: str, error: str):
    """Persist messages we couldn't process."""
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
        # Emit any pending reports
        SQS_TRACKER.emit_all_reports()
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
                    # Track processing start
                    process_start = time.time()

                    local_path = work_dir / Path(key).name
                    s3.download_file(bucket, key, str(local_path))
                    metrics = compute_file_metrics(local_path)
                    seen.add(key)

                    # Infer sensor from key
                    sensor = infer_sensor_from_key(key)

                    # Track processing
                    process_end = time.time()
                    process_latency = (process_end - process_start) * 1000

                    SQS_TRACKER.log_processing(
                        bucket=bucket,
                        key=key,
                        sensor=sensor,
                        success=True,
                        latency_ms=int(process_latency)
                    )

                    batch_summary["files_processed"].append({"bucket": bucket, "key": key, **metrics})
                    batch_summary["total_files"] += 1
                    print(f"[POLLER] Processed {key} from {bucket}: {metrics}", flush=True)
                except ClientError as ce:
                    err = f"S3 error for {bucket}/{key}: {ce}"
                    print(f"[POLLER] ✗ {err}", flush=True)
                    SQS_TRACKER.log_processing(
                        bucket=bucket,
                        key=key,
                        sensor=infer_sensor_from_key(key),
                        success=False,
                        error=str(ce)
                    )
                    log_failed_message(message_id, body, err)
                except Exception as exc:
                    err = f"Unexpected error for {bucket}/{key}: {exc}\n{traceback.format_exc()}"
                    print(f"[POLLER] ✗ {err}", flush=True)
                    SQS_TRACKER.log_processing(
                        bucket=bucket,
                        key=key,
                        sensor=infer_sensor_from_key(key),
                        success=False,
                        error=str(exc)
                    )
                    log_failed_message(message_id, body, err)

        except Exception as exc:
            err = f"Failed to parse/handle message: {exc}\n{traceback.format_exc()}"
            print(f"[POLLER] ✗ {err}", flush=True)
            log_failed_message(message_id, body, err)

        finally:
            try:
                sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            except ClientError as ce:
                print(f"[POLLER] ✗ Failed to delete message {message_id}: {ce}", flush=True)

    # Emit report for batch
    if batch_summary["files_processed"]:
        emit_combined_report(batch_summary)

    # Emit any completed window reports
    SQS_TRACKER.emit_all_reports()
PY