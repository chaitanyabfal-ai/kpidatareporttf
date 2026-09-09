#!/usr/bin/env bash
#
# Garage S3 Integration Test & Setup
# Verifies Tailscale VPN connectivity and Garage credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Load .env
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

echo "=================================================="
echo "GARAGE S3 INTEGRATION TEST"
echo "=================================================="
echo ""

# 1. Tailscale connectivity
echo "1. Testing Tailscale VPN connectivity..."
GARAGE_ENDPOINT_URL="${GARAGE_ENDPOINT_URL:-http://100.78.2.20:3900}"
GARAGE_IP=$(echo "${GARAGE_ENDPOINT_URL}" | cut -d'/' -f3 | cut -d':' -f1)

if ping -c 1 -W 2 "${GARAGE_IP}" >/dev/null 2>&1; then
  echo "   ✓ Garage endpoint IP is reachable: ${GARAGE_IP}"
else
  echo "   ✗ Cannot reach Garage endpoint IP: ${GARAGE_IP}"
  echo "   → Check Tailscale VPN status: tailscale status"
  exit 1
fi

echo ""

# 2. Garage credentials
echo "2. Checking Garage S3 credentials..."
GARAGE_KEY="${GARAGE_ACCESS_KEY_ID:-}"
GARAGE_SECRET="${GARAGE_SECRET_ACCESS_KEY:-}"

if [[ -z "${GARAGE_KEY}" ]] || [[ "${GARAGE_KEY}" == "YOUR_GARAGE_KEY" ]]; then
  echo "   ✗ GARAGE_ACCESS_KEY_ID is not set in .env"
  echo "   → Set credentials in .env and try again"
  exit 1
fi

if [[ -z "${GARAGE_SECRET}" ]] || [[ "${GARAGE_SECRET}" == "YOUR_GARAGE_SECRET" ]]; then
  echo "   ✗ GARAGE_SECRET_ACCESS_KEY is not set in .env"
  echo "   → Set credentials in .env and try again"
  exit 1
fi

echo "   ✓ Credentials found (key: ${GARAGE_KEY:0:10}...)"

echo ""

# 3. Test Garage S3 connection
echo "3. Testing Garage S3 bucket access..."
source "${PROJECT_ROOT}/kpidatatf/bin/activate"

python3 << 'PYTHON'
import os
import sys
import boto3
from botocore.config import Config

try:
    garage_s3 = boto3.client(
        "s3",
        endpoint_url=os.environ.get("GARAGE_ENDPOINT_URL"),
        aws_access_key_id=os.environ.get("GARAGE_ACCESS_KEY_ID"),
        aws_secret_access_key=os.environ.get("GARAGE_SECRET_ACCESS_KEY"),
        region_name="garage",
        config=Config(s3={"addressing_style": "path"})
    )
    
    # List buckets
    response = garage_s3.list_buckets()
    buckets = response.get('Buckets', [])
    
    print(f"   ✓ Connected to Garage S3!")
    print(f"   ✓ Available buckets: {[b['Name'] for b in buckets]}")
    
    # Try accessing the configured bucket
    target_bucket = os.environ.get('GARAGE_S3_BUCKET', 'data')
    try:
        objs = garage_s3.list_objects_v2(Bucket=target_bucket, MaxKeys=5)
        csv_count = len([o for o in objs.get('Contents', []) if o['Key'].endswith('.csv')])
        total_count = len(objs.get('Contents', []))
        print(f"   ✓ Bucket '{target_bucket}': {total_count} objects, {csv_count} CSV files")
    except Exception as e:
        print(f"   ✗ Cannot access bucket '{target_bucket}': {e}")
        sys.exit(1)
        
except Exception as e:
    print(f"   ✗ Failed to connect: {e}")
    sys.exit(1)
PYTHON

echo ""
echo "=================================================="
echo "✓ GARAGE INTEGRATION TEST PASSED"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Run garage_sync.py to download CSVs from Garage"
echo "  2. CSVs will be uploaded to AWS S3"
echo "  3. S3 events trigger SNS→SQS→EC2 pipeline"
echo ""
echo "To start continuous sync:"
echo "  python3 scripts/garage_sync.py"
echo ""
