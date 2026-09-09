#!/usr/bin/env python3
"""
KPI Aggregator: Aggregates 6-minute window reports into hourly and daily summaries.
Run via cron: 0 * * * * /opt/ilds_ingestdigest/kpi_data/bin/python3 /opt/ilds_ingestdigest/scripts/kpi_aggregator.py
"""
import json
from pathlib import Path
from datetime import datetime, timedelta
from collections import defaultdict

def aggregate_6min_to_hourly():
    """Aggregate 6-minute reports into hourly summaries."""
    window_dir = Path("./data/kpi_reports/windows")
    hourly_dir = Path("./data/kpi_reports/hourly")
    hourly_dir.mkdir(parents=True, exist_ok=True)

    # Group 6-min reports by hour
    hourly_groups = defaultdict(list)
    for window_file in window_dir.glob("*.json"):
        with open(window_file) as f:
            report = json.load(f)
        window_key = report.get("window", {}).get("key", "")
        # Parse window key: 2026-09-04T06:30:00Z -> hour: 2026-09-04T06:00:00Z
        try:
            dt = datetime.strptime(window_key, "%Y-%m-%dT%H:%M:%SZ")
            hour_key = dt.replace(minute=0, second=0, microsecond=0).strftime("%Y-%m-%dT%H:00:00Z")
            hourly_groups[hour_key].append(report)
        except ValueError:
            continue

    # Generate hourly reports
    for hour_key, reports in hourly_groups.items():
        hourly_report = {
            "report_id": f"hourly_{hour_key}",
            "hour": hour_key,
            "total_6min_windows": len(reports),
            "ingestion_volume": {
                "total_files": 0,
                "failed_files": 0,
                "by_sensor": defaultdict(int),
                "success_rate_percent": 0.0,
                "expected_files": 0,
                "missing_files_count": 0
            },
            "latency_ms": {
                "avg": 0,
                "p50": 0,
                "p95": 0,
                "p99": 0
            },
            "completeness": {
                "expected_files": 0,
                "actual_files": 0,
                "missing_files_count": 0,
                "missing_files": []
            },
            "sensor_health": {
                "by_sensor": {},
                "imbalance_ratio": 1.0
            }
        }

        total_files = 0
        failed_files = 0
        all_latencies = []
        sensor_totals = defaultdict(int)
        expected_per_sensor = {}
        all_missing = []

        for report in reports:
            vol = report.get("ingestion_volume", {})
            sqs = report.get("sqs_processing", {})
            if not vol and sqs:
                vol = {
                    "total_files": sqs.get("files_processed", 0),
                    "failed_files": sqs.get("error_count", 0),
                    "by_sensor": sqs.get("by_sensor", {}),
                    "expected_files": 0,
                    "missing_files_count": sqs.get("error_count", 0),
                }
            lat = report.get("latency_ms", {})
            if "download" in lat:
                lat = lat["download"]
            comp = report.get("completeness", {})
            sens = report.get("sensor_health", {}).get("by_sensor", {})

            hourly_report["ingestion_volume"]["total_files"] += vol.get("total_files", 0)
            hourly_report["ingestion_volume"]["failed_files"] += vol.get("failed_files", 0)
            failed_files += vol.get("failed_files", 0)
            hourly_report["ingestion_volume"]["expected_files"] += vol.get("expected_files", 0)
            hourly_report["ingestion_volume"]["missing_files_count"] += vol.get("missing_files_count", 0)

            hourly_report["completeness"]["expected_files"] += comp.get("expected_files", 0)
            hourly_report["completeness"]["actual_files"] += comp.get("actual_files", 0)
            hourly_report["completeness"]["missing_files_count"] += comp.get("missing_files_count", 0)
            hourly_report["completeness"]["missing_files"].extend(comp.get("missing_files", []))

            for sensor, count in vol.get("by_sensor", {}).items():
                sensor_totals[sensor] += count
                expected_per_sensor[sensor] = sens.get(sensor, {}).get("expected", 0)

            if lat.get("avg", 0) > 0:
                all_latencies.append(lat.get("avg", 0))

        hourly_report["ingestion_volume"]["by_sensor"] = dict(sensor_totals)
        hourly_report["ingestion_volume"]["success_rate_percent"] = round(
            (1 - (failed_files / max(1, hourly_report["ingestion_volume"]["total_files"]))) * 100, 2
        )

        all_latencies.sort()
        n = len(all_latencies)
        if n > 0:
            hourly_report["latency_ms"] = {
                "avg": round(sum(all_latencies) / n, 2),
                "p50": all_latencies[n//2],
                "p95": all_latencies[int(n*0.95)] if n > 1 else all_latencies[0],
                "p99": all_latencies[int(n*0.99)] if n > 1 else all_latencies[0]
            }

        hourly_report["sensor_health"]["by_sensor"] = {
            sensor: {
                "ingested": sensor_totals.get(sensor, 0),
                "expected": expected_per_sensor.get(sensor, 0),
                "gap_seconds": 0
            }
            for sensor in sensor_totals
        }

        values = list(sensor_totals.values())
        if values:
            hourly_report["sensor_health"]["imbalance_ratio"] = round(max(values) / max(1, min(values)), 2)

        # Save hourly report
        hour_file = hourly_dir / f"{hour_key}.json"
        hour_file.write_text(json.dumps(hourly_report, indent=2))
        print(f"[AGGREGATOR] Generated hourly report: {hour_key}")

    # Clean up processed windows
    for window_file in window_dir.glob("*.json"):
        window_file.unlink()

def aggregate_hourly_to_daily():
    """Aggregate hourly reports into daily summaries."""
    hourly_dir = Path("./data/kpi_reports/hourly")
    daily_dir = Path("./data/kpi_reports/daily")
    daily_dir.mkdir(parents=True, exist_ok=True)

    # Group hourly reports by day
    daily_groups = defaultdict(list)
    for hour_file in hourly_dir.glob("*.json"):
        with open(hour_file) as f:
            report = json.load(f)
        hour_key = report.get("hour", "")
        try:
            dt = datetime.strptime(hour_key, "%Y-%m-%dT%H:00:00Z")
            day_key = dt.strftime("%Y-%m-%d")
            daily_groups[day_key].append(report)
        except ValueError:
            continue

    # Generate daily reports
    for day_key, reports in daily_groups.items():
        daily_report = {
            "report_id": f"daily_{day_key}",
            "date": day_key,
            "total_hours": len(reports),
            "ingestion_volume": {
                "total_files": 0,
                "failed_files": 0,
                "by_sensor": defaultdict(int),
                "success_rate_percent": 0.0,
                "expected_files": 0,
                "missing_files_count": 0
            },
            "latency_ms": {
                "avg": 0,
                "p50": 0,
                "p95": 0,
                "p99": 0
            },
            "completeness": {
                "completeness_ratio": 0.0
            },
            "sensor_health": {
                "by_sensor": {},
                "imbalance_ratio": 1.0,
                "best_sensor": "",
                "worst_sensor": ""
            }
        }

        total_files = 0
        expected_files = 0
        all_latencies = []
        sensor_totals = defaultdict(int)
        sensor_expected = {}

        for report in reports:
            vol = report.get("ingestion_volume", {})
            lat = report.get("latency_ms", {}).get("avg", 0)

            daily_report["ingestion_volume"]["total_files"] += vol.get("total_files", 0)
            daily_report["ingestion_volume"]["failed_files"] += vol.get("failed_files", 0)
            daily_report["ingestion_volume"]["expected_files"] += vol.get("expected_files", 0)
            daily_report["ingestion_volume"]["missing_files_count"] += vol.get("missing_files_count", 0)

            total_files += vol.get("total_files", 0)
            expected_files += vol.get("expected_files", 0)

            for sensor, count in vol.get("by_sensor", {}).items():
                sensor_totals[sensor] += count
                sensor_expected[sensor] = report.get("sensor_health", {}).get("by_sensor", {}).get(sensor, {}).get("expected", 0)

            if lat > 0:
                all_latencies.append(lat)

        daily_report["ingestion_volume"]["by_sensor"] = dict(sensor_totals)
        if expected_files > 0:
            daily_report["ingestion_volume"]["success_rate_percent"] = round(
                (total_files / expected_files) * 100, 2
            )

        all_latencies.sort()
        n = len(all_latencies)
        if n > 0:
            daily_report["latency_ms"] = {
                "avg": round(sum(all_latencies) / n, 2),
                "p50": all_latencies[n//2],
                "p95": all_latencies[int(n*0.95)] if n > 1 else all_latencies[0],
                "p99": all_latencies[int(n*0.99)] if n > 1 else all_latencies[0]
            }

        daily_report["sensor_health"]["by_sensor"] = {
            sensor: {
                "ingested": sensor_totals.get(sensor, 0),
                "expected": sensor_expected.get(sensor, 0),
                "gap_seconds": 0
            }
            for sensor in sensor_totals
        }

        values = list(sensor_totals.values())
        if values:
            daily_report["sensor_health"]["imbalance_ratio"] = round(max(values) / max(1, min(values)), 2)
            daily_report["sensor_health"]["best_sensor"] = max(sensor_totals, key=sensor_totals.get)
            daily_report["sensor_health"]["worst_sensor"] = min(sensor_totals, key=sensor_totals.get)

        if expected_files > 0:
            daily_report["completeness"]["completeness_ratio"] = round(total_files / expected_files, 2)

        # Save daily report
        day_file = daily_dir / f"{day_key}.json"
        day_file.write_text(json.dumps(daily_report, indent=2))
        print(f"[AGGREGATOR] Generated daily report: {day_key}")

    # Clean up processed hourly reports
    for hour_file in hourly_dir.glob("*.json"):
        hour_file.unlink()

def main():
    print("=" * 60)
    print("KPI AGGREGATOR STARTED")
    print("=" * 60)
    print("[AGGREGATOR] Aggregating 6-min reports to hourly...", flush=True)
    aggregate_6min_to_hourly()
    print("[AGGREGATOR] Aggregating hourly reports to daily...", flush=True)
    aggregate_hourly_to_daily()
    print("[AGGREGATOR] Aggregation complete", flush=True)

if __name__ == "__main__":
    main()
