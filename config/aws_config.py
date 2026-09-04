import os
from pathlib import Path

# Load .env file explicitly (python-dotenv has issues in some environments)
env_file = Path(__file__).resolve().parent.parent / ".env"
if env_file.exists():
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ[key] = value

AWS_REGION = os.getenv("AWS_REGION", "ap-south-1")
S3_BUCKET = os.getenv("S3_BUCKET", "453914763342-cflds-dev-ap-south-1-ilds-txdata-20260901")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "https://sqs.ap-south-1.amazonaws.com/453914763342/ilds_queue_1")
WATCH_DIRECTORY = os.getenv("WATCH_DIRECTORY", "./data/incoming_csvs")

GARAGE_ENDPOINT_URL = os.getenv("GARAGE_ENDPOINT_URL", "http://100.78.2.20:3900")
GARAGE_S3_BUCKET = os.getenv("GARAGE_S3_BUCKET", "data")
GARAGE_ACCESS_KEY_ID = os.getenv("GARAGE_ACCESS_KEY_ID", "")
GARAGE_SECRET_ACCESS_KEY = os.getenv("GARAGE_SECRET_ACCESS_KEY", "")
GARAGE_REGION = "garage"

SENSOR_PREFIXES = {
    "BFA12": "BFA12/",
    "BFA8": "BFA8/",
    "BFA3": "BFA3/",
}
