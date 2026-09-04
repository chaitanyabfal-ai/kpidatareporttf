# README_CHANGES.md — what changed vs. your original repo

## Read SECURITY.md first
Real secrets were found in this repo (SSH key, Garage credentials in
`RUNBOOK.md`). Rotate them — see SECURITY.md for exact steps.

## Files replaced

| File | What changed |
|---|---|
| `scripts/provision_aws_resources.sh` | **New canonical script.** Consolidates 8 near-duplicate provisioning scripts into one. Fixes: missing `BFA12/` prefix creation, missing S3→SNS→SQS wiring (the old `provision_aws_resources_final.sh`/`provision_aws_resources.sh` created the resources but never connected them — that's what `fix_pipeline_final.sh` was hacking around with fragile string-based JSON escaping). Uses `jq` throughout instead of manual quote-escaping. Replaces the IAM-user + static-access-key EC2 pattern with an IAM role + instance profile (no long-lived keys to leak). Fixes the EC2 user-data script: `amazon-linux-extras` doesn't exist on Amazon Linux 2023 (swapped for `dnf`), the old user-data ran `python scripts/ec2_garage_kpi_runner.sh` on a *bash* script (fixed to invoke it correctly and via the systemd unit instead of a bare `nohup`), and the placeholder `your-org` clone URL is now the real repo. |
| `systemd/ec2-sqs-poller.service` | Fixed a malformed `[Install]` section (missing newline — systemd would fail to parse the unit as originally pasted). Aligned `User=`/paths with the `bfa` user your existing `garage-sync.service` already uses (the version floating around in chat used `ubuntu`, which doesn't match this repo). |
| `RUNBOOK.md` | Redacted the real Garage credentials that were printed in §5.3 (see SECURITY.md). Fixed the `your-org` placeholder clone URL. Pointed all references at the single `provision_aws_resources.sh` instead of the `_final` variant. |
| `.gitignore` | Didn't exist before. Now excludes `.env`, `*.pem`, the venv, caches, and bulk CSV data. |
| `SECURITY.md` | New — rotation steps and git-history cleanup instructions. |

## Files intentionally dropped from this package

Delete these from your repo — they're either superseded or actively unsafe:

- `scripts/provision_all_aws.sh`
- `scripts/provision_aws_cli_json.sh`
- `scripts/provision_aws_cloud_stack.sh`
- `scripts/provision_aws_resources_final.sh`
- `scripts/provision_final_working.sh`
- `scripts/provision_v7_style.sh`
- `scripts/provision_working.sh`
- `scripts/fix_pipeline_final.sh`
  *(all eight superseded by the single `scripts/provision_aws_resources.sh`)*
- `scripts/ec2_sqs_kpi_poller_debug.py`
  *(prints `.env` variable values — including secrets, if any get added
  later — to stdout/journal logs; a debug leftover that shouldn't ship)*
- `ilds-key-1787743292.pem`, `.env` *(see SECURITY.md — rotate, then remove)*
- The ~7,130-file `BFA12_Batch*` dump under `data/incoming_csvs/`
  *(638 MB test-data flood; this package keeps only the two original
  documented samples, `BFA3_Batch102...` and `BFA8_Batch101...`)*

## Files kept unmodified (already correct)

`config/aws_config.py`, `scripts/garage_sync.py`, `scripts/s3_uploader.py`,
`scripts/garage_kpi_processor.py`, `scripts/aws_s3_setup_check.py`,
`scripts/test_garage_integration.sh`, `scripts/ec2_garage_kpi_runner.sh`,
`scripts/ec2_sqs_kpi_poller.sh`, `systemd/garage-sync.service`,
`tests/test_uploader_contract.py`, `requirements.txt`, `.env.example`.

## One doc/behavior mismatch worth knowing about

`RUNBOOK.md` §10.3 describes the S3 key layout as
`raw-sensor-data/BFA8/...`, but the actual uploader
(`scripts/s3_uploader.py::build_s3_key`) writes directly to `BFA8/...`,
`BFA3/...`, `BFA12/...` at the bucket root — no `raw-sensor-data/` prefix.
Functionally this doesn't break anything (the S3→SNS notification has no
prefix filter, so it fires either way), but the docs describe a layout
that isn't what the code does. Left as-is in this pass since it's cosmetic;
worth a follow-up doc fix or an actual prefix change, your call.

---

## Update — this package adds

### Terraform IaC (`infra/terraform/`)
A second provisioning path alongside the bash script, provisioning the
identical resources (S3 + versioning + encryption + prefixes, SNS topic +
policy, SQS queue + policy, the subscription wiring, IAM role/instance
profile, optional EC2 instance). See `GETTING_STARTED.md` Path C for usage.
Pick one tool per environment — don't run both bash and Terraform against
the same bucket/queue names, since bucket notification config is a
full-replace API and whichever runs last silently wins.

### Poller resilience fix (`scripts/ec2_sqs_kpi_poller.sh`)
Found while debugging live: the poller crashed the *entire systemd
service* on the first message it couldn't process (e.g. an S3 object that
no longer exists), and never deleted that message first — so the same
message reappeared after the visibility timeout and crashed it again,
indefinitely. Fixed:
- every message now gets `delete_message` in a `finally` block regardless
  of success/failure
- per-notification S3 download + processing wrapped in its own try/except
- failures are written to `data/kpi_reports/failed_messages/<id>.json`
  (bucket, key, error, timestamp) instead of silently vanishing
- `receive_message` retries on transient `ClientError` instead of dying

### Diagnostic script (`scripts/diagnose_s3_sqs_bridge.sh`)
Checks the S3 -> SNS -> SQS chain in order (notification config, SNS topic
policy, SQS queue policy, subscription confirmation state) and does a live
upload-and-watch test. Use this first whenever "file lands in S3 but
nothing downstream happens."

### `GETTING_STARTED.md`
New master run-through covering: local-only (no AWS), full pipeline via
bash, full pipeline via Terraform, and AWS-provisioned-but-poller-local as
a fourth middle-ground option — plus verification and teardown for each.
