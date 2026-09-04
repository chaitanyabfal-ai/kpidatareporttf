#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Activate the project venv if present; otherwise fall back to system Python.
if [[ -f "${PROJECT_ROOT}/kpi_data/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/kpi_data/bin/activate"
fi

export PYTHONPATH="${PROJECT_ROOT}:${PYTHONPATH:-}"

# Optional: bring in environment variables from .env if present.
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${PROJECT_ROOT}/.env"
  set +a
fi

# Default local directory for Garage CSV downloads.
LOCAL_DIR="${LOCAL_DIR:-${PROJECT_ROOT}/data/garage_kpi_downloads}"
BUCKET_NAME="${GARAGE_S3_BUCKET:-${S3_BUCKET:-data}}"
JSON_OUTPUT="${JSON_OUTPUT:-${PROJECT_ROOT}/data/kpi_reports/garage_kpi_report.json}"
CSV_OUTPUT="${CSV_OUTPUT:-${PROJECT_ROOT}/data/kpi_reports/garage_kpi_batch_summary.csv}"

mkdir -p "${LOCAL_DIR}"
mkdir -p "$(dirname "${JSON_OUTPUT}")"
mkdir -p "$(dirname "${CSV_OUTPUT}")"

python3 "${SCRIPT_DIR}/garage_kpi_processor.py" \
  --local-dir "${LOCAL_DIR}" \
  --bucket "${BUCKET_NAME}" \
  --json-output "${JSON_OUTPUT}" \
  --csv-output "${CSV_OUTPUT}"

# Optional: keep the runner alive with periodic polling.
# Uncomment the block below if you want the EC2 instance to refresh KPI data every 300 seconds.
# while true; do
#   python3 "${SCRIPT_DIR}/garage_kpi_processor.py" \
#     --local-dir "${LOCAL_DIR}" \
#     --bucket "${BUCKET_NAME}" \
#     --json-output "${JSON_OUTPUT}" \
#     --csv-output "${CSV_OUTPUT}"
#   sleep 300
# done
