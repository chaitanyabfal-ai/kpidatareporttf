#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import boto3
from botocore.config import Config

from config.aws_config import (
    AWS_REGION,
    GARAGE_ACCESS_KEY_ID,
    GARAGE_ENDPOINT_URL,
    GARAGE_REGION,
    GARAGE_S3_BUCKET,
    GARAGE_SECRET_ACCESS_KEY,
)


def get_garage_client():
    return boto3.client(
        "s3",
        endpoint_url=GARAGE_ENDPOINT_URL,
        aws_access_key_id=GARAGE_ACCESS_KEY_ID,
        aws_secret_access_key=GARAGE_SECRET_ACCESS_KEY,
        region_name=GARAGE_REGION,
        config=Config(s3={"addressing_style": "path"}),
    )


def list_csv_keys(client, bucket_name: str) -> List[str]:
    response = client.list_objects_v2(Bucket=bucket_name)
    return [
        obj["Key"]
        for obj in response.get("Contents", [])
        if obj.get("Key", "").lower().endswith(".csv")
    ]


def parse_batch_metadata(key: str) -> Tuple[str, str | None]:
    filename = os.path.basename(key)
    match = re.search(r"(?P<sensor>BFA[0-9]+)[_-]Batch(?P<batch>[0-9]+)", filename, re.IGNORECASE)
    if match:
        return match.group("sensor").upper(), match.group("batch")

    # fallback match for generic Batch names without sensor prefix
    match = re.search(r"Batch(?P<batch>[0-9]+)", filename, re.IGNORECASE)
    if match:
        sensor = "BFA8" if "BFA8" in filename.upper() else "BFA3"
        return sensor, match.group("batch")

    return "UNKNOWN", None


def download_csvs(keys: Iterable[str], local_dir: str, client, bucket_name: str):
    os.makedirs(local_dir, exist_ok=True)
    local_paths: List[str] = []
    for key in keys:
        file_name = os.path.basename(key)
        local_path = os.path.join(local_dir, file_name)
        if not os.path.exists(local_path):
            client.download_file(bucket_name, key, local_path)
        local_paths.append(local_path)
    return local_paths


def summarize_numeric_columns(df: pd.DataFrame) -> Dict[str, Dict[str, float]]:
    stats: Dict[str, Dict[str, float]] = {}
    for column in ["Voltage", "Pressure"]:
        if column not in df.columns:
            continue
        values = pd.to_numeric(df[column], errors="coerce").dropna()
        if values.empty:
            continue
        stats[column] = {
            "mean": float(values.mean()),
            "min": float(values.min()),
            "max": float(values.max()),
            "count": int(values.count()),
        }
    return stats


def summarize_file(path: str) -> Dict[str, object]:
    df = pd.read_csv(path)
    stats = summarize_numeric_columns(df)
    sensor, batch = parse_batch_metadata(path)
    return {
        "file": os.path.basename(path),
        "sensor": sensor,
        "batch": batch,
        "rows": int(len(df)),
        "numeric_columns": stats,
    }


def summarize_pairing(keys: Iterable[str]) -> Dict[str, object]:
    batch_to_sensors: Dict[str, set] = defaultdict(set)
    batch_to_files: Dict[str, List[str]] = defaultdict(list)

    for key in keys:
        sensor, batch = parse_batch_metadata(key)
        if batch is None:
            continue
        batch_to_sensors[batch].add(sensor)
        batch_to_files[batch].append(key)

    matched_pairs = 0
    missing_pairs = 0
    per_batch: Dict[str, Dict[str, int]] = {}

    for batch, sensors in sorted(batch_to_sensors.items()):
        sensor_set = set(sensors)
        has_bfa8 = "BFA8" in sensor_set
        has_bfa3 = "BFA3" in sensor_set
        if has_bfa8 and has_bfa3:
            matched_pairs += 1
            pair_status = "matched"
        else:
            missing_pairs += 1
            pair_status = "missing_pair"

        per_batch[batch] = {
            "sensors": sorted(sensor_set),
            "received_files": len(batch_to_files.get(batch, [])),
            "pair_status": pair_status,
        }

    return {
        "matched_pairs": matched_pairs,
        "missing_pairs": missing_pairs,
        "per_batch": per_batch,
    }


def summarize_kpis(keys: List[str], local_dir: str, client, bucket_name: str) -> Dict[str, object]:
    local_paths = download_csvs(keys, local_dir, client, bucket_name)
    file_summaries = [summarize_file(path) for path in local_paths]

    sensor_totals: Dict[str, int] = defaultdict(int)
    batch_totals: Dict[str, int] = defaultdict(int)
    aggregate_means: Dict[str, float] = defaultdict(float)
    aggregated_columns: Dict[str, List[float]] = defaultdict(list)

    for item in file_summaries:
        sensor = item["sensor"]
        batch = item["batch"]
        if sensor != "UNKNOWN":
            sensor_totals[sensor] += 1
        if batch:
            batch_totals[batch] += 1

        for column, values in item["numeric_columns"].items():
            aggregated_columns[column].append(values["mean"])

    for column, values in aggregated_columns.items():
        if values:
            aggregate_means[column] = float(sum(values) / len(values))

    pairing_summary = summarize_pairing(keys)

    summary = {
        "schema_version": 1,
        "garage_bucket": bucket_name,
        "garage_csv_count": len(keys),
        "received_files": len(keys),
        "missing_files": pairing_summary["missing_pairs"],
        "sensor_totals": dict(sorted(sensor_totals.items())),
        "batch_totals": dict(sorted(batch_totals.items())),
        "average_means": dict(sorted(aggregate_means.items())),
        "pairing": pairing_summary,
        "file_summaries": file_summaries,
        "summary": {
            "total_files_received": len(keys),
            "total_files_missing": pairing_summary["missing_pairs"],
            "matched_pairs": pairing_summary["matched_pairs"],
            "missing_pairs": pairing_summary["missing_pairs"],
            "average_means": dict(sorted(aggregate_means.items())),
        },
    }
    return summary


def export_batch_csv(summary: Dict[str, object], output_path: str):
    rows = []
    for item in summary.get("file_summaries", []):
        row = {
            "file_name": item.get("file"),
            "sensor": item.get("sensor"),
            "batch": item.get("batch"),
            "rows": item.get("rows"),
            "mean_voltage": item.get("numeric_columns", {}).get("Voltage", {}).get("mean"),
            "mean_pressure": item.get("numeric_columns", {}).get("Pressure", {}).get("mean"),
        }
        rows.append(row)

    df = pd.DataFrame(rows)
    if df.empty:
        df = pd.DataFrame([
            {
                "file_name": "",
                "sensor": "",
                "batch": "",
                "rows": 0,
                "mean_voltage": None,
                "mean_pressure": None,
            }
        ])

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output, index=False)
    return output


def main():
    parser = argparse.ArgumentParser(description="Compute Garage ingestion KPI summaries for CSV files.")
    parser.add_argument("--local-dir", default="./data/garage_kpi_downloads", help="Directory for downloaded CSVs")
    parser.add_argument("--bucket", default=GARAGE_S3_BUCKET, help="Garage S3 bucket name")
    parser.add_argument("--json-output", default=None, help="Optional output path for JSON summary")
    parser.add_argument("--csv-output", default=None, help="Optional output path for KPI CSV summary")
    args = parser.parse_args()

    client = get_garage_client()
    csv_keys = list_csv_keys(client, args.bucket)
    summary = summarize_kpis(csv_keys, args.local_dir, client, args.bucket)

    print(json.dumps(summary, indent=2, default=str))

    if args.json_output:
        output_path = Path(args.json_output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(summary, indent=2, default=str) + "\n", encoding="utf-8")
        print(f"\nSaved KPI report to {output_path}")

    if args.csv_output:
        output_path = export_batch_csv(summary, args.csv_output)
        print(f"Saved CSV KPI summary to {output_path}")


if __name__ == "__main__":
    main()
