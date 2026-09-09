from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pandas as pd
import streamlit as st


PROJECT_ROOT = Path(__file__).resolve().parents[1]
REPORT_ROOT = PROJECT_ROOT / "data" / "kpi_reports"
REPORT_DIRS = {"Daily": "daily", "Hourly": "hourly", "6-minute": "windows", "Live SQS": ""}


def read_reports(tier: str) -> list[dict[str, Any]]:
    """Read valid JSON KPI reports for one aggregation tier."""
    if tier == "Live SQS":
        path = REPORT_ROOT / "ec2_queue_kpi_latest.json"
        if not path.exists():
            return []
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        report["_source"] = path.name
        return [report]

    directory = REPORT_ROOT / REPORT_DIRS[tier]
    reports: list[dict[str, Any]] = []
    if not directory.exists():
        return reports

    for path in sorted(directory.glob("*.json")):
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        report["_source"] = path.name
        reports.append(report)
    return reports


def report_timestamp(report: dict[str, Any], tier: str) -> pd.Timestamp | None:
    value = report.get("date") if tier == "Daily" else report.get("hour")
    if tier == "6-minute":
        value = report.get("window", {}).get("key")
    if tier == "Live SQS":
        value = report.get("processed_at")
        if value:
            return pd.to_datetime(value, unit="s", utc=True, errors="coerce")
    if not value:
        return None
    timestamp = pd.to_datetime(value, utc=True, errors="coerce")
    return None if pd.isna(timestamp) else timestamp


def report_rows(reports: list[dict[str, Any]], tier: str) -> pd.DataFrame:
    rows = []
    for report in reports:
        volume = report.get("ingestion_volume", {})
        sqs = report.get("sqs_processing", {})
        completeness = report.get("completeness", {})
        latency = report.get("latency_ms", {})
        if "download" in latency:
            latency = latency["download"]
        timestamp = report_timestamp(report, tier)
        if timestamp is None:
            continue
        rows.append(
            {
                "timestamp": timestamp,
                "files": volume.get("total_files", report.get("total_files", sqs.get("files_processed", 0))),
                "failed": volume.get("failed_files", sqs.get("error_count", 0)),
                "expected": volume.get("expected_files", 0),
                "missing": volume.get("missing_files_count", sqs.get("error_count", 0)),
                "success_rate": volume.get("success_rate_percent", 100 if sqs.get("error_count", 0) == 0 else 0),
                "completeness": completeness.get("completeness_ratio"),
                "latency_avg": latency.get("avg", 0),
                "latency_p95": latency.get("p95", 0),
                "by_sensor": volume.get("by_sensor", sqs.get("by_sensor", {})),
                "source": report.get("_source", "unknown"),
            }
        )
    frame = pd.DataFrame(rows)
    if not frame.empty:
        frame = frame.sort_values("timestamp").reset_index(drop=True)
    return frame


def sensor_frame(reports: list[dict[str, Any]]) -> pd.DataFrame:
    totals: dict[str, int] = {}
    expected: dict[str, int] = {}
    gaps: dict[str, int] = {}
    for report in reports:
        sqs = report.get("sqs_processing", {})
        health = report.get("sensor_health", {}).get("by_sensor", {})
        for sensor, values in health.items():
            totals[sensor] = totals.get(sensor, 0) + values.get("ingested", 0)
            expected[sensor] = expected.get(sensor, 0) + values.get("expected", 0)
            gaps[sensor] = max(gaps.get(sensor, 0), values.get("gap_seconds", 0))
        sensor_counts = report.get("ingestion_volume", {}).get("by_sensor", sqs.get("by_sensor", {}))
        for sensor, count in sensor_counts.items():
            if sensor not in health:
                totals[sensor] = totals.get(sensor, 0) + count
    sensors = sorted(set(totals) | set(expected))
    return pd.DataFrame(
        [
            {
                "Sensor": sensor,
                "Ingested": totals.get(sensor, 0),
                "Expected": expected.get(sensor, 0),
                "Gap (sec)": gaps.get(sensor, 0),
            }
            for sensor in sensors
        ]
    )


def format_number(value: float | int) -> str:
    return f"{value:,.0f}"


st.set_page_config(page_title="ILDS Ingestion Control", page_icon="+", layout="wide")
st.markdown(
    """
    <style>
    @import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;600;700&display=swap');
    :root { --ink: #e9f0ed; --muted: #91a39d; --line: #29433d; --panel: #10211e; --accent: #c8f169; --orange: #f2a65a; }
    .stApp { background: #081412; color: var(--ink); }
    .block-container { max-width: 1440px; padding: 2.4rem 3.2rem 4rem; }
    h1, h2, h3, p, div, span, label { font-family: 'Space Grotesk', sans-serif; }
    h1 { letter-spacing: 0; font-size: 2.8rem; line-height: 1; margin-bottom: .35rem; }
    h2 { font-size: 1.15rem; margin-top: 1.8rem; }
    [data-testid='stMetric'] { background: var(--panel); border: 1px solid var(--line); padding: 1rem 1.1rem; border-radius: 6px; }
    [data-testid='stMetricLabel'] { color: var(--muted); font-size: .78rem; text-transform: uppercase; letter-spacing: .08em; }
    [data-testid='stMetricValue'] { color: var(--ink); font-family: 'DM Mono', monospace; font-size: 1.65rem; }
    .eyebrow { color: var(--accent); font-family: 'DM Mono', monospace; font-size: .74rem; letter-spacing: .16em; text-transform: uppercase; }
    .subtitle { color: var(--muted); margin-bottom: 1.6rem; }
    .status { color: var(--accent); font-family: 'DM Mono', monospace; font-size: .8rem; }
    .stButton button { border: 1px solid var(--line); color: var(--ink); background: #122823; border-radius: 4px; }
    .stDataFrame { border: 1px solid var(--line); }
    </style>
    """,
    unsafe_allow_html=True,
)

header, controls = st.columns([2.8, 1], vertical_alignment="bottom")
with header:
    st.markdown("<div class='eyebrow'>ILDS / ingestion observatory</div>", unsafe_allow_html=True)
    st.title("KPI control room")
    st.markdown("<div class='subtitle'>A live read on sensor delivery, completeness, and pipeline latency.</div>", unsafe_allow_html=True)
with controls:
    tier = st.selectbox("Report resolution", list(REPORT_DIRS), index=0)
    if st.button("Refresh reports", use_container_width=True):
        st.cache_data.clear()
        st.rerun()

reports = read_reports(tier)
frame = report_rows(reports, tier)

if frame.empty:
    st.info(
        f"No {tier.lower()} reports found in `{(REPORT_ROOT / REPORT_DIRS[tier]).relative_to(PROJECT_ROOT)}`. "
        "Start the sync or aggregator and refresh this view."
    )
    st.stop()

latest = frame.iloc[-1]
previous = frame.iloc[-2] if len(frame) > 1 else None


def delta(column: str) -> float | None:
    if previous is None:
        return None
    return float(latest[column] - previous[column])


st.markdown(f"<div class='status'>[ ONLINE ] &nbsp; / &nbsp; {len(frame)} {tier.lower()} snapshots</div>", unsafe_allow_html=True)
metrics = st.columns(5)
metrics[0].metric("Files ingested", format_number(latest["files"]), delta=delta("files"))
metrics[1].metric("Success rate", f"{latest['success_rate']:.1f}%", delta=f"{delta('success_rate'):.1f} pts" if delta("success_rate") is not None else None)
metrics[2].metric("Missing files", format_number(latest["missing"]), delta=delta("missing"), delta_color="inverse")
metrics[3].metric("Avg latency", f"{latest['latency_avg']:.0f} ms", delta=delta("latency_avg"), delta_color="inverse")
metrics[4].metric("P95 latency", f"{latest['latency_p95']:.0f} ms", delta=delta("latency_p95"), delta_color="inverse")

st.markdown("## Delivery pulse")
chart_left, chart_right = st.columns([1.65, 1])
with chart_left:
    chart_data = frame.set_index("timestamp")[["files", "expected"]].rename(columns={"files": "Ingested", "expected": "Expected"})
    st.line_chart(chart_data, color=["#c8f169", "#42675e"], height=310)
with chart_right:
    latency_data = frame.set_index("timestamp")[["latency_avg", "latency_p95"]].rename(columns={"latency_avg": "Average", "latency_p95": "P95"})
    st.line_chart(latency_data, color=["#f2a65a", "#d96c4e"], height=310)

st.markdown("## Sensor health")
health_left, health_right = st.columns([1.25, 1])
with health_left:
    sensors = sensor_frame(reports)
    if sensors.empty:
        st.caption("Sensor-level health will appear when reports include sensor counters.")
    else:
        st.bar_chart(sensors.set_index("Sensor")[["Ingested", "Expected"]], color=["#c8f169", "#42675e"], height=260)
with health_right:
    if sensors.empty:
        st.caption("No sensor breakdown available.")
    else:
        st.dataframe(sensors, hide_index=True, use_container_width=True, height=260)

st.markdown("## Recent snapshots")
recent = frame.tail(12).copy()
recent["timestamp"] = recent["timestamp"].dt.strftime("%Y-%m-%d %H:%M UTC")
recent = recent[["timestamp", "files", "missing", "success_rate", "latency_avg", "source"]]
recent.columns = ["Snapshot", "Files", "Missing", "Success %", "Avg latency ms", "Source"]
st.dataframe(recent.iloc[::-1], hide_index=True, use_container_width=True)

st.caption(f"Last snapshot: {latest['timestamp'].strftime('%Y-%m-%d %H:%M UTC')}  ·  Source: {latest['source']}")