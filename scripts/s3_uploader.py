import os
import sys
import time
from pathlib import Path
from typing import Optional

import boto3
import pandas as pd
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from config.aws_config import AWS_REGION, S3_BUCKET, WATCH_DIRECTORY

s3_client = boto3.client("s3", region_name=AWS_REGION)


VALID_SENSORS = {"BFA8", "BFA3", "BFA12"}


def infer_sensor_from_filename(filename: str) -> str:
    name = os.path.basename(filename).upper()
    for sensor in ("BFA12", "BFA8", "BFA3"):
        if name.startswith(sensor):
            return sensor
    return "BFA8"


def validate_csv_schema(file_path: str) -> bool:
    df = pd.read_csv(file_path)
    cols = {str(col).strip().replace("\ufeff", "") for col in df.columns}
    if "Timestamp" not in cols:
        raise ValueError(f"{file_path}: missing Timestamp column")

    normalized_cols = {str(col).strip().replace("\ufeff", "").lower() for col in df.columns}
    has_voltage = any("voltage" in col for col in normalized_cols)
    has_pressure = any("pressure" in col for col in normalized_cols)

    if has_voltage or has_pressure:
        return True
    raise ValueError(f"{file_path}: expected either Voltage or Pressure column (or channel variants like CH1_Voltage)")


def build_s3_key(file_path: str, sensor: Optional[str] = None) -> str:
    filename = os.path.basename(file_path)
    if not filename.endswith(".csv"):
        raise ValueError(f"{file_path}: only .csv files may be uploaded")

    sensor = (sensor or infer_sensor_from_filename(filename)).upper()
    if sensor not in VALID_SENSORS:
        raise ValueError(f"Unsupported sensor '{sensor}'")

    if filename.startswith(f"{sensor}_"):
        final_name = filename
    else:
        final_name = filename.replace(filename.split("_Batch")[0], sensor, 1) if "_Batch" in filename else f"{sensor}_{filename}"

    return f"{sensor}/{final_name}"


def upload_file_to_s3(file_path: str, sensor: Optional[str] = None):
    if not file_path.endswith(".csv"):
        return

    time.sleep(0.5)
    try:
        validate_csv_schema(file_path)
        s3_key = build_s3_key(file_path, sensor=sensor)
        print(f"[UPLOADING] {file_path} -> s3://{S3_BUCKET}/{s3_key}", flush=True)
        s3_client.upload_file(file_path, S3_BUCKET, s3_key)
        print(f"[SUCCESS] Uploaded {os.path.basename(file_path)} to {s3_key}", flush=True)
    except Exception as exc:
        print(f"[ERROR] Failed to upload {file_path}: {exc}", flush=True)


class CSVUploadHandler(FileSystemEventHandler):
    def on_created(self, event):
        if not event.is_directory:
            upload_file_to_s3(event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            upload_file_to_s3(event.src_path)


def process_existing_files():
    print("[SCAN] Checking for existing CSV files...", flush=True)
    for root, _, files in os.walk(WATCH_DIRECTORY):
        for file in files:
            if file.endswith(".csv"):
                full_path = os.path.join(root, file)
                upload_file_to_s3(full_path)


if __name__ == "__main__":
    if not os.path.exists(WATCH_DIRECTORY):
        print(f"[FATAL] Directory does not exist: {WATCH_DIRECTORY}", flush=True)
        sys.exit(1)

    print("--- AWS S3 WATCHER STARTED ---", flush=True)
    process_existing_files()

    observer = Observer()
    event_handler = CSVUploadHandler()
    observer.schedule(event_handler, path=WATCH_DIRECTORY, recursive=True)
    observer.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
