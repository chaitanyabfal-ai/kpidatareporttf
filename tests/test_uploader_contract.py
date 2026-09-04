import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.s3_uploader import build_s3_key, validate_csv_schema


def test_csv_schema_accepts_voltage():
    csv_path = ROOT / "data" / "incoming_csvs" / "BFA8_Batch101_2026-08-31_09-00-00.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.write_text(
        "Timestamp,Voltage\n"
        "1787827704.531533,2.6925\n"
        "1787827704.541806,2.6915\n",
        encoding="utf-8",
    )

    assert validate_csv_schema(str(csv_path)) is True
    assert build_s3_key(str(csv_path), sensor="BFA8").startswith("BFA8/")


def test_csv_schema_accepts_pressure():
    csv_path = ROOT / "data" / "incoming_csvs" / "BFA3_Batch102_2026-08-31_09-05-00.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.write_text(
        "Timestamp,Pressure\n"
        "1787827704.531533,2.6925\n"
        "1787827704.541806,2.6915\n",
        encoding="utf-8",
    )

    assert validate_csv_schema(str(csv_path)) is True
    assert build_s3_key(str(csv_path), sensor="BFA3").startswith("BFA3/")


def test_csv_schema_accepts_bfa12_channel_voltage_columns():
    csv_path = ROOT / "data" / "incoming_csvs" / "BFA12_Batch6595_2026-08-28_10-41-34.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.write_text(
        "Timestamp,CH1_Voltage,CH2_Voltage\n"
        "1787893712.723186,2.691625,2.038375\n"
        "1787893712.7469847,2.691375,2.038875\n",
        encoding="utf-8",
    )

    assert validate_csv_schema(str(csv_path)) is True
    assert build_s3_key(str(csv_path), sensor="BFA12").startswith("BFA12/")
