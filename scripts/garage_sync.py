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
from pathlib import Path

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
        response = garage_s3.list_objects_v2(Bucket=GARAGE_S3_BUCKET)

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
                garage_s3.download_file(GARAGE_S3_BUCKET, key, local_path)
                print(f"[GARAGE] ✓ Downloaded: {key}", flush=True)

                # Validate schema
                try:
                    validate_csv_schema(local_path)
                    print(f"[GARAGE] ✓ Schema valid: {key}", flush=True)
                except ValueError as ve:
                    print(f"[GARAGE] ✗ Schema validation failed for {key}: {ve}", flush=True)
                    continue

                # Upload to AWS S3
                try:
                    upload_file_to_s3(local_path)
                    print(f"[GARAGE] ⬆ Uploaded to AWS S3: {key}", flush=True)
                    PROCESSED_FILES.add(key)
                    downloaded_count += 1
                except Exception as e:
                    print(f"[GARAGE] ✗ Upload failed for {key}: {e}", flush=True)

            except ClientError as ce:
                print(f"[GARAGE] ✗ Download failed for {key}: {ce}", flush=True)
            except Exception as e:
                print(f"[GARAGE] ✗ Unexpected error processing {key}: {e}", flush=True)

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
        print(f"[GARAGE] Sync complete. Processed {count} new files.", flush=True)
    else:
        print("[GARAGE] Starting continuous sync...", flush=True)
        try:
            poll_count = 0
            while True:
                poll_count += 1
                print(f"\n[GARAGE] Poll #{poll_count} at {time.strftime('%Y-%m-%d %H:%M:%S')}", flush=True)
                count = download_new_csvs()
                if count > 0:
                    print(f"[GARAGE] ✓ {count} new files processed", flush=True)
                else:
                    print(f"[GARAGE] No new files", flush=True)
                print(f"[GARAGE] Waiting {args.interval}s until next poll...", flush=True)
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\n[GARAGE] Sync stopped by user", flush=True)
            sys.exit(0)


if __name__ == "__main__":
    main()
