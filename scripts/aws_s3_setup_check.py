import os
import sys
from pathlib import Path

import boto3

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from config.aws_config import AWS_REGION, S3_BUCKET, SQS_QUEUE_URL


def check_s3_access():
    s3 = boto3.client("s3", region_name=AWS_REGION)
    try:
        response = s3.list_objects_v2(Bucket=S3_BUCKET, MaxKeys=1)
        print(f"S3 bucket accessible: {S3_BUCKET}")
        print(response.get("KeyCount", 0), "object(s) visible")
    except Exception as exc:
        print(f"S3 check failed: {exc}")


def check_sqs_access():
    sqs = boto3.client("sqs", region_name=AWS_REGION)
    try:
        response = sqs.get_queue_attributes(
            QueueUrl=SQS_QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        print(f"SQS queue reachable: {SQS_QUEUE_URL}")
        print(response)
    except Exception as exc:
        print(f"SQS check failed: {exc}")


if __name__ == "__main__":
    check_s3_access()
    check_sqs_access()
