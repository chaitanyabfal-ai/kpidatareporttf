# AWS Setup Notes

## Required S3 bucket

- `471112814693-bfa-dev-ap-south-1-ilds-transmitter-data`

## Required S3 prefixes

- `BFA8/`
- `BFA3/`

## Required SQS queue

- `https://sqs.ap-south-1.amazonaws.com/471112814693/ilds_queue_1`

## Required object naming pattern

- `BFA8/BFA8_BatchXXX_YYYY-MM-DD_HH-MM-SS.csv`
- `BFA3/BFA3_BatchXXX_YYYY-MM-DD_HH-MM-SS.csv`

## CSV contract

- Must include `Timestamp`
- Must include either `Voltage` or `Pressure`

## Local test command

```bash
python -m pytest -q tests/test_uploader_contract.py
```
