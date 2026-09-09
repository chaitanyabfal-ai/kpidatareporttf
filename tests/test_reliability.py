from datetime import datetime, timezone

import pandas as pd

from scripts.reliability import summarize_timestamp_reliability


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
