from datetime import datetime, timezone

import pandas as pd

from scripts.reliability import summarize_heartbeat, summarize_timestamp_reliability


def test_reliability_reports_frequency_and_gap():
    frame = pd.DataFrame(
        {
            "Timestamp": [
                "2026-09-09T12:00:00Z",
                "2026-09-09T12:00:01Z",
                "2026-09-09T12:00:05Z",
            ]
        }
    )

    result = summarize_timestamp_reliability(
        frame,
        observed_at=datetime(2026, 9, 9, 12, 0, 6, tzinfo=timezone.utc),
    )

    assert result["sample_count"] == 3
    assert result["expected_interval_seconds"] == 2.5
    assert result["observed_frequency_hz"] == 0.4
    assert result["gap_count"] == 1
    assert result["max_gap_seconds"] == 4.0
    assert result["arrival_delay_seconds"] == 1.0
    assert result["timestamp_status"] == "irregular"


def test_reliability_detects_out_of_order_samples():
    frame = pd.DataFrame(
        {
            "Timestamp": [
                "2026-09-09T12:00:01Z",
                "2026-09-09T12:00:00Z",
            ]
        }
    )

    result = summarize_timestamp_reliability(frame)

    assert result["out_of_order_count"] == 1
    assert result["timestamp_status"] == "irregular"


def test_reliability_reports_freshness_and_sampling_rules():
    frame = pd.DataFrame(
        {
            "Timestamp": [
                "2026-09-09T10:00:00Z",
                "2026-09-09T10:00:01Z",
            ]
        }
    )

    result = summarize_timestamp_reliability(
        frame,
        observed_at=datetime(2026, 9, 9, 11, 31, tzinfo=timezone.utc),
    )

    assert result["freshness"]["accepted"] is False
    assert result["freshness"]["status"] == "expired"
    assert result["sampling"]["target_frequency_hz"] == 100.0
    assert result["sampling"]["frequency_status"] == "off_target"
    assert result["sampling"]["minimum_window_met"] is False


def test_heartbeat_turns_off_after_fifteen_minutes():
    observed_at = datetime(2026, 9, 9, 12, 15, tzinfo=timezone.utc)
    upload_at = datetime(2026, 9, 9, 12, 0, tzinfo=timezone.utc)

    assert summarize_heartbeat(upload_at, observed_at)["status"] == "ACTIVE"
    assert summarize_heartbeat(
        datetime(2026, 9, 9, 11, 59, 59, tzinfo=timezone.utc), observed_at
    )["status"] == "OFF"
