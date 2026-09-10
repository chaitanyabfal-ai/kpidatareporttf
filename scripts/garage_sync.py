#!/usr/bin/env python3
"""
Garage S3 → AWS S3 Integration
Continuously syncs CSV files from Garage S3 (via Tailscale VPN) to AWS S3,
triggering the SNS→SQS→EC2 KPI processing pipeline.
"""
import argparse
import os
import sys
import time
import json
from pathlib import Path
from datetime import datetime, timedelta
from collections import defaultdict

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, ConnectionError

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from config.aws_config import (
    GARAGE_ENDPOINT_URL,
    GARAGE_S3_BUCKET,
    GARAGE_ACCESS_KEY_ID,
    GARAGE_SECRET_ACCESS_KEY,
    GARAGE_REGION,
)
from scripts.s3_uploader import upload_file_to_s3, validate_csv_schema

LOCAL_DOWNLOAD_DIR = "./data/incoming_csvs"
PROCESSED_FILES = set()

# === KPI TRACKING ===
class IngestionKPITracker:
    EXPECTED_PER_SENSOR = {"BFA8": 2, "BFA3": 2, "BFA12": 2}
    EXPECTED_TOTAL_PER_6MIN = sum(EXPECTED_PER_SENSOR.values())

    def __init__(self):
        self.metrics_buffer = []
        self.window_stats = defaultdict(lambda: {
            "files_ingested": 0,
            "files_failed": 0,
            "by_sensor": defaultdict(int),
            "latencies_ms": [],
            "missing_files": [],
            "window_start": None,
            "window_end": None
        })
        self.last_ingest = {sensor: None for sensor in self.EXPECTED_PER_SENSOR.keys()}
        self.window_dir = Path("./data/kpi_reports/windows")
        self.window_dir.mkdir(parents=True, exist_ok=True)

    def get_6min_window(self, timestamp=None):
        """Get 6-minute window identifier: YYYY-MM-DDTHH:MM:00Z"""
        ts = timestamp or datetime.utcnow()
        base = ts.replace(second=0, microsecond=0)
        window_start_minute = (base.minute // 6) * 6
        return base.replace(minute=window_start_minute).strftime("%Y-%m-%dT%H:%M:00Z")

    def get_window_range(self, window_key):
        """Get start and end timestamps for a 6-min window"""
        start = datetime.strptime(window_key, "%Y-%m-%dT%H:%M:00Z")
        end = start + timedelta(minutes=6)
        return start, end

    def log_ingestion(self, sensor, filename, success=True, latency_ms=None, error=None):
        """Log file ingestion event."""
        window = self.get_6min_window()
        start, end = self.get_window_range(window)

        event = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "window": window,
            "window_start": start.isoformat() + "Z",
            "window_end": end.isoformat() + "Z",
            "sensor": sensor,
            "filename": filename,
            "success": success,
            "latency_ms": latency_ms,
            "error": error
        }
        self.metrics_buffer.append(event)

        if window not in self.window_stats:
            self.window_stats[window]["window_start"] = start.isoformat() + "Z"
            self.window_stats[window]["window_end"] = end.isoformat() + "Z"

        if success:
            self.window_stats[window]["files_ingested"] += 1
            self.window_stats[window]["by_sensor"][sensor] += 1
            if latency_ms:
                self.window_stats[window]["latencies_ms"].append(latency_ms)
        else:
            self.window_stats[window]["files_failed"] += 1
            self.window_stats[window]["missing_files"].append({
                "sensor": sensor,
                "filename": filename,
                "error": str(error)
            })

        self.last_ingest[sensor] = datetime.utcnow()

    def generate_6min_report(self, window_key):
        """Generate KPI report for completed 6-minute window."""
        if window_key not in self.window_stats:
            return None

        stats = self.window_stats[window_key]
        latencies = stats.get("latencies_ms", [])
        latencies.sort()
        n = len(latencies)

        # Calculate expected vs actual
        expected_total = self.EXPECTED_TOTAL_PER_6MIN
        actual_total = stats.get("files_ingested", 0)
        failed_total = stats.get("files_failed", 0)
        success_rate = (actual_total / expected_total * 100) if expected_total > 0 else 0.0

        # Calculate ingest gaps per sensor
        ingest_gaps = {}
        for sensor in self.EXPECTED_PER_SENSOR:
            last = self.last_ingest.get(sensor)
            gap_seconds = 0
            if last:
                gap_seconds = (datetime.utcnow() - last).total_seconds()
            ingest_gaps[sensor] = gap_seconds

        report = {
            "report_id": f"kpi_{window_key}",
            "window": {
                "key": window_key,
                "start": stats.get("window_start"),
                "end": stats.get("window_end"),
                "duration_seconds": 360
            },
            "ingestion_volume": {
                "total_files": actual_total,
                "failed_files": failed_total,
                "by_sensor": dict(stats.get("by_sensor", {})),
                "success_rate_percent": round(success_rate, 2),
                "expected_files": expected_total,
                "missing_files_count": expected_total - actual_total
            },
            "latency_ms": {
                "download": {"avg": 0, "p50": 0, "p95": 0, "p99": 0} if not latencies else {
                    "avg": round(sum(latencies) / n, 2),
                    "p50": latencies[n//2],
                    "p95": latencies[int(n*0.95)] if n > 0 else 0,
                    "p99": latencies[int(n*0.99)] if n > 0 else 0
                }
            },
            "completeness": {
                "expected_files": expected_total,
                "actual_files": actual_total,
                "missing_files_count": expected_total - actual_total,
                "missing_files": stats.get("missing_files", []),
                "last_ingest_gap_seconds": {
                    sensor: int(gap) for sensor, gap in ingest_gaps.items()
                }
            },
            "sensor_health": {
                "by_sensor": {
                    sensor: {
                        "ingested": stats.get("by_sensor", {}).get(sensor, 0),
                        "expected": self.EXPECTED_PER_SENSOR.get(sensor, 0),
                        "gap_seconds": int(ingest_gaps.get(sensor, 0))
                    }
                    for sensor in self.EXPECTED_PER_SENSOR
                },
                "imbalance_ratio": max(stats.get("by_sensor", {}).values() or [1]) / max(1, min(stats.get("by_sensor", {}).values() or [1]))
            },
            "system_health": {
                "garage_status": "up",
                "aws_s3_status": "up",
                "sync_uptime_seconds": 0
            }
        }

        return report

    def emit_window_report(self, window_key):
        """Save 6-min window report to file."""
        report = self.generate_6min_report(window_key)
        if not report:
            return

        report_path = self.window_dir / f"{window_key}.json"
        report_path.write_text(json.dumps(report, indent=2))
        print(f"[KPI] Generated 6-min report: {window_key}")

    def emit_all_reports(self):
        """Emit reports for all completed windows."""
        for window_key in list(self.window_stats.keys()):
            start, _ = self.get_window_range(window_key)
            if (datetime.utcnow() - start) >= timedelta(minutes=6):
                self.emit_window_report(window_key)
                del self.window_stats[window_key]

# Initialize tracker
KPI_TRACKER = IngestionKPITracker()

# === END KPI TRACKING ===

# Validate credentials
if not GARAGE_ACCESS_KEY_ID or GARAGE_ACCESS_KEY_ID == "YOUR_GARAGE_KEY":
    print("[ERROR] GARAGE_ACCESS_KEY_ID not configured in .env")
    print("        See GARAGE_SETUP.md for instructions")
    sys.exit(1)

if not GARAGE_SECRET_ACCESS_KEY or GARAGE_SECRET_ACCESS_KEY == "YOUR_GARAGE_SECRET":
    print("[ERROR] GARAGE_SECRET_ACCESS_KEY not configured in .env")
    print("        See GARAGE_SETUP.md for instructions")
    sys.exit(1)

# Initialize Garage S3 client
try:
    garage_s3 = boto3.client(
        "s3",
        endpoint_url=GARAGE_ENDPOINT_URL,
        aws_access_key_id=GARAGE_ACCESS_KEY_ID,
        aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY,
        region_name=GARAGE_REGION,
        config=Config(s3={"addressing_style": "path"}),
    )
    print(f"[GARAGE] Connected to {GARAGE_ENDPOINT_URL}")
except Exception as e:
    print(f"[ERROR] Failed to initialize Garage S3 client: {e}")
    sys.exit(1)

def download_new_csvs():
    """Download new CSV files from Garage S3 and upload to AWS S3."""
    try:
        print(f"[GARAGE] Listing objects in bucket '{GARAGE_S3_BUCKET}'...", flush=True)
        response = {
            "Contents": [
                obj
                for page in garage_s3.get_paginator("list_objects_v2").paginate(
                    Bucket=GARAGE_S3_BUCKET
                )
                for obj in page.get("Contents", [])
            ]
        }

        if "Contents" not in response:
            print(f"[GARAGE] Bucket is empty", flush=True)
            return 0

        downloaded_count = 0
        for obj in response["Contents"]:
            key = obj["Key"]
            if not key.endswith(".csv"):
                continue

            if key in PROCESSED_FILES:
                continue

            local_path = os.path.join(LOCAL_DOWNLOAD_DIR, os.path.basename(key))

            if os.path.exists(local_path):
                PROCESSED_FILES.add(key)
                print(f"[GARAGE] Already processed: {key}", flush=True)
                continue

            try:
                print(f"[GARAGE] ⬇ Downloading {key}...", flush=True)
                download_start = time.time()
                garage_s3.download_file(GARAGE_S3_BUCKET, key, local_path)
                download_end = time.time()
                download_latency = (download_end - download_start) * 1000
                print(f"[GARAGE] ✓ Downloaded: {key}", flush=True)

                # Validate schema
                try:
                    validate_csv_schema(local_path)
                    print(f"[GARAGE] ✓ Schema valid: {key}", flush=True)
                except ValueError as ve:
                    print(f"[GARAGE] ✗ Schema validation failed for {key}: {ve}", flush=True)
                    KPI_TRACKER.log_ingestion(
                        sensor="UNKNOWN", filename=key, success=False,
                        latency_ms=int(download_latency), error=str(ve)
                    )
                    continue

                # Upload to AWS S3
                try:
                    upload_start = time.time()
                    upload_file_to_s3(local_path)
                    upload_end = time.time()
                    upload_latency = (upload_end - upload_start) * 1000
                    total_latency = download_latency + upload_latency

                    # Infer sensor from filename
                    sensor = "BFA8"
                    if "BFA3" in key:
                        sensor = "BFA3"
                    elif "BFA12" in key:
                        sensor = "BFA12"

                    KPI_TRACKER.log_ingestion(
                        sensor=sensor, filename=key, success=True,
                        latency_ms=int(total_latency)
                    )
                    print(f"[GARAGE] ⬆ Uploaded to AWS S3: {key}", flush=True)
                    PROCESSED_FILES.add(key)
                    downloaded_count += 1
                except Exception as e:
                    print(f"[GARAGE] ✗ Upload failed for {key}: {e}", flush=True)
                    KPI_TRACKER.log_ingestion(
                        sensor="UNKNOWN", filename=key, success=False,
                        latency_ms=int(download_latency), error=str(e)
                    )

            except ClientError as ce:
                print(f"[GARAGE] ✗ Download failed for {key}: {ce}", flush=True)
                KPI_TRACKER.log_ingestion(
                    sensor="UNKNOWN", filename=key, success=False,
                    error=str(ce)
                )
            except Exception as e:
                print(f"[GARAGE] ✗ Unexpected error processing {key}: {e}", flush=True)
                KPI_TRACKER.log_ingestion(
                    sensor="UNKNOWN", filename=key, success=False,
                    error=str(e)
                )

        return downloaded_count

    except ConnectionError as ce:
        print(f"[GARAGE] ✗ Connection error (Tailscale VPN?): {ce}", flush=True)
        return 0
    except ClientError as ce:
        if ce.response["Error"]["Code"] == "InvalidAccessKeyId":
            print(f"[GARAGE] ✗ Invalid credentials. Check .env configuration.", flush=True)
        else:
            print(f"[GARAGE] ✗ AWS client error: {ce}", flush=True)
        return 0
    except Exception as e:
        print(f"[GARAGE] ✗ Unexpected error: {e}", flush=True)
        return 0

def main():
    """Main entry point with CLI argument parsing."""
    parser = argparse.ArgumentParser(description="Sync CSV files from Garage S3 to AWS S3")
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run sync once and exit (default: continuous)",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=5,
        help="Polling interval in seconds (default: 5)",
    )
    args = parser.parse_args()

    os.makedirs(LOCAL_DOWNLOAD_DIR, exist_ok=True)
    print("=" * 60, flush=True)
    print("GARAGE S3 → AWS S3 SYNC", flush=True)
    print("=" * 60, flush=True)
    print(f"Garage endpoint: {GARAGE_ENDPOINT_URL}", flush=True)
    print(f"Garage bucket:   {GARAGE_S3_BUCKET}", flush=True)
    print(f"Local download:  {LOCAL_DOWNLOAD_DIR}", flush=True)
    print(f"Mode:            {'One-time' if args.once else f'Continuous (interval: {args.interval}s)'}", flush=True)
    print("=" * 60, flush=True)
    print("", flush=True)

    if args.once:
        print("[GARAGE] Running one-time sync...", flush=True)
        count = download_new_csvs()
        KPI_TRACKER.emit_all_reports()
        print(f"[GARAGE] Sync complete. Processed {count} new files.", flush=True)
    else:
        print("[GARAGE] Starting continuous sync...", flush=True)
        try:
            poll_count = 0
            while True:
                poll_count += 1
                current_window = KPI_TRACKER.get_6min_window()
                print(f"\n[GARAGE] Poll #{poll_count} at {time.strftime('%Y-%m-%d %H:%M:%S')}", flush=True)
                count = download_new_csvs()

                # Emit reports for completed windows
                KPI_TRACKER.emit_all_reports()

                if count > 0:
                    print(f"[GARAGE] ✓ {count} new files processed", flush=True)
                else:
                    print(f"[GARAGE] No new files", flush=True)
                print(f"[GARAGE] Waiting {args.interval}s until next poll...", flush=True)
                time.sleep(args.interval)
        except KeyboardInterrupt:
            KPI_TRACKER.emit_all_reports()
            print("\n[GARAGE] Sync stopped by user", flush=True)
            sys.exit(0)

if __name__ == "__main__":
    main()