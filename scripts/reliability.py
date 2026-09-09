"""Reliability metrics derived from sensor CSV timestamps."""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd


TIMESTAMP_COLUMNS = ("Timestamp", "timestamp", "time", "Time")


def parse_sensor_timestamps(frame: pd.DataFrame) -> pd.DatetimeIndex:
    """Parse common sensor timestamp formats into UTC timestamps."""
    column = next((name for name in TIMESTAMP_COLUMNS if name in frame.columns), None)
    if column is None:
        return pd.DatetimeIndex([], tz="UTC")

    values = frame[column]
    numeric = pd.to_numeric(values, errors="coerce")
    if numeric.notna().mean() > 0.8:
        timestamps = pd.to_datetime(numeric, unit="s", utc=True, errors="coerce")
    else:
        timestamps = pd.to_datetime(values, utc=True, errors="coerce")
    return pd.DatetimeIndex(timestamps.dropna()).sort_values()


def summarize_timestamp_reliability(
    frame: pd.DataFrame,
    observed_at: datetime | None = None,
) -> dict[str, Any]:
    """Return cadence, gap, ordering, and freshness metrics for one CSV."""
    timestamps = parse_sensor_timestamps(frame)
    if timestamps.empty:
        return {
            "sample_count": 0,
            "expected_interval_seconds": None,
            "observed_frequency_hz": None,
            "gap_count": 0,
            "max_gap_seconds": None,
            "out_of_order_count": 0,
            "first_sample_at": None,
            "last_sample_at": None,
            "sample_age_seconds": None,
            "arrival_delay_seconds": None,
            "timestamp_status": "missing_or_invalid",
        }

    original_column = next((name for name in TIMESTAMP_COLUMNS if name in frame.columns), None)
    original = pd.to_datetime(frame[original_column], utc=True, errors="coerce") if original_column else pd.Series(dtype="datetime64[ns, UTC]")
    if original_column:
        numeric = pd.to_numeric(frame[original_column], errors="coerce")
        if numeric.notna().mean() > 0.8:
            original = pd.to_datetime(numeric, unit="s", utc=True, errors="coerce")
    valid_original = original.dropna()
    out_of_order_count = int((valid_original.diff().dt.total_seconds().dropna() < 0).sum())

    intervals = pd.Series(timestamps[1:] - timestamps[:-1]).dt.total_seconds()
    positive_intervals = intervals[intervals > 0]
    expected_interval = float(positive_intervals.median()) if not positive_intervals.empty else None
    gap_threshold = expected_interval * 1.5 if expected_interval else None
    gap_count = int((positive_intervals > gap_threshold).sum()) if gap_threshold else 0
    max_gap = float(positive_intervals.max()) if not positive_intervals.empty else None

    now = observed_at or datetime.now(timezone.utc)
    now_timestamp = pd.Timestamp(now, tz="UTC") if now.tzinfo is None else pd.Timestamp(now)
    last_sample = timestamps[-1]
    sample_age = max(0.0, (now_timestamp - last_sample).total_seconds())

    status = "healthy"
    if gap_count or out_of_order_count:
        status = "irregular"
    if sample_age > max((expected_interval or 0) * 3, 60):
        status = "stale"

    return {
        "sample_count": int(len(timestamps)),
        "expected_interval_seconds": round(expected_interval, 3) if expected_interval is not None else None,
        "observed_frequency_hz": round(1 / expected_interval, 6) if expected_interval else None,
        "gap_count": gap_count,
        "max_gap_seconds": round(max_gap, 3) if max_gap is not None else None,
        "out_of_order_count": out_of_order_count,
        "first_sample_at": timestamps[0].isoformat(),
        "last_sample_at": last_sample.isoformat(),
        "sample_age_seconds": round(sample_age, 3),
        "arrival_delay_seconds": round(sample_age, 3),
        "timestamp_status": status,
    }


def summarize_csv_reliability(path: str | Path, observed_at: datetime | None = None) -> dict[str, Any]:
    """Read a sensor CSV and calculate timestamp reliability metrics."""
    return summarize_timestamp_reliability(pd.read_csv(path), observed_at=observed_at)
