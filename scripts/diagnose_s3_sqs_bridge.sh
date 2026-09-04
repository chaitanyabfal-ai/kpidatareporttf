#!/usr/bin/env bash
#
# Diagnose the S3 -> SNS -> SQS bridge for the ILDS pipeline.
# Run this from your workstation (needs AWS CLI configured with permissions
# to read S3/SNS/SQS config — not the EC2 instance).
#
# Usage:
#   AWS_REGION=ap-south-1 BUCKET_NAME=453914763342-ilds-sensor-data \
#   QUEUE_NAME=ilds_queue_1 ./scripts/diagnose_s3_sqs_bridge.sh
#
set -uo pipefail   # NOT -e: we want to keep checking even if one check fails

AWS_REGION="${AWS_REGION:-ap-south-1}"
BUCKET_NAME="${BUCKET_NAME:?Set BUCKET_NAME}"
QUEUE_NAME="${QUEUE_NAME:-ilds_queue_1}"

PASS=0
FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ℹ️  $1"; }

echo "=== 1. S3 bucket notification configuration ==="
NOTIF_JSON="$(aws s3api get-bucket-notification-configuration --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" 2>&1)"
if echo "${NOTIF_JSON}" | jq -e '.TopicConfigurations // empty' >/dev/null 2>&1; then
    TOPIC_ARN="$(echo "${NOTIF_JSON}" | jq -r '.TopicConfigurations[0].TopicArn')"
    EVENTS="$(echo "${NOTIF_JSON}" | jq -r '.TopicConfigurations[0].Events | join(",")')"
    ok "Bucket has a TopicConfiguration -> ${TOPIC_ARN} (events: ${EVENTS})"
    FILTER="$(echo "${NOTIF_JSON}" | jq -c '.TopicConfigurations[0].Filter // empty')"
    if [[ -n "${FILTER}" && "${FILTER}" != "null" ]]; then
        info "A key filter is set: ${FILTER} — if your uploaded object's key doesn't match this filter, no event fires. Compare against the actual key you uploaded."
    fi
else
    bad "No TopicConfigurations on bucket '${BUCKET_NAME}'. This is very likely your root cause — S3 isn't configured to notify anything."
    echo "     Raw response: ${NOTIF_JSON}"
    TOPIC_ARN=""
fi

echo ""
echo "=== 2. SNS topic policy allows S3 to publish ==="
if [[ -n "${TOPIC_ARN}" ]]; then
    TOPIC_ATTRS="$(aws sns get-topic-attributes --topic-arn "${TOPIC_ARN}" --region "${AWS_REGION}" 2>&1)"
    POLICY="$(echo "${TOPIC_ATTRS}" | jq -r '.Attributes.Policy // empty' 2>/dev/null)"
    if [[ -n "${POLICY}" ]]; then
        SOURCE_ARN="$(echo "${POLICY}" | jq -r '.Statement[] | select(.Action=="sns:Publish") | .Condition.ArnLike."aws:SourceArn" // .Condition.StringEquals."aws:SourceArn" // empty' 2>/dev/null)"
        EXPECTED="arn:aws:s3:::${BUCKET_NAME}"
        if [[ "${SOURCE_ARN}" == "${EXPECTED}" ]]; then
            ok "SNS topic policy allows s3.amazonaws.com to publish, scoped to ${EXPECTED}"
        else
            bad "SNS topic policy's SourceArn condition is '${SOURCE_ARN}', expected '${EXPECTED}'. A mismatch here silently blocks S3's publish attempt."
        fi
    else
        bad "SNS topic '${TOPIC_ARN}' has no access policy allowing s3.amazonaws.com to publish."
    fi
else
    info "Skipped — no topic ARN found in step 1."
fi

echo ""
echo "=== 3. SQS queue exists and its policy allows SNS to send ==="
QUEUE_URL="$(aws sqs get-queue-url --queue-name "${QUEUE_NAME}" --region "${AWS_REGION}" --query QueueUrl --output text 2>&1)"
if [[ "${QUEUE_URL}" == arn:* || "${QUEUE_URL}" == https://* ]]; then
    ok "Queue exists: ${QUEUE_URL}"
    QUEUE_ARN="$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names QueueArn --region "${AWS_REGION}" --query Attributes.QueueArn --output text)"
    QATTRS="$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names Policy --region "${AWS_REGION}" 2>&1)"
    QPOLICY="$(echo "${QATTRS}" | jq -r '.Attributes.Policy // empty' 2>/dev/null)"
    if [[ -n "${QPOLICY}" ]]; then
        Q_SOURCE_ARN="$(echo "${QPOLICY}" | jq -r '.Statement[] | select(.Action=="sqs:SendMessage") | .Condition.ArnEquals."aws:SourceArn" // empty' 2>/dev/null)"
        if [[ "${Q_SOURCE_ARN}" == "${TOPIC_ARN}" ]]; then
            ok "SQS queue policy allows sns.amazonaws.com to send, scoped to ${TOPIC_ARN}"
        else
            bad "SQS queue policy's SourceArn is '${Q_SOURCE_ARN}', expected the SNS topic ARN '${TOPIC_ARN}'. Mismatch = SNS's publish-to-queue silently fails."
        fi
    else
        bad "SQS queue '${QUEUE_NAME}' has no policy allowing sns.amazonaws.com to send messages."
    fi
else
    bad "Queue '${QUEUE_NAME}' not found in region ${AWS_REGION}: ${QUEUE_URL}"
    QUEUE_ARN=""
fi

echo ""
echo "=== 4. SNS subscription (SQS endpoint) is confirmed, not pending ==="
if [[ -n "${TOPIC_ARN:-}" ]]; then
    SUBS="$(aws sns list-subscriptions-by-topic --topic-arn "${TOPIC_ARN}" --region "${AWS_REGION}" 2>&1)"
    SUB_ARN="$(echo "${SUBS}" | jq -r --arg qarn "${QUEUE_ARN}" '.Subscriptions[] | select(.Endpoint==$qarn) | .SubscriptionArn' 2>/dev/null)"
    if [[ -z "${SUB_ARN}" ]]; then
        bad "No subscription found from topic ${TOPIC_ARN} to queue ${QUEUE_ARN}."
    elif [[ "${SUB_ARN}" == "PendingConfirmation" ]]; then
        bad "Subscription exists but is PendingConfirmation — SQS subscriptions confirm automatically on 'aws sns subscribe'; this state usually means the subscribe call itself failed partway. Re-run the subscribe step."
    else
        ok "Confirmed subscription: ${SUB_ARN}"
    fi
else
    info "Skipped — no topic ARN found in step 1."
fi

echo ""
echo "=== 5. Live test: upload a probe file and watch for the SQS message ==="
if [[ -n "${QUEUE_URL:-}" && "${QUEUE_URL}" == https://* ]]; then
    BEFORE="$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names ApproximateNumberOfMessages --region "${AWS_REGION}" --query Attributes.ApproximateNumberOfMessages --output text)"
    info "Messages in queue before test: ${BEFORE}"
    PROBE_KEY="BFA8/BFA8_diagnostic_probe_$(date +%s).csv"
    printf 'Timestamp,Voltage\n%s,1.0\n' "$(date +%s)" > /tmp/probe.csv
    aws s3 cp /tmp/probe.csv "s3://${BUCKET_NAME}/${PROBE_KEY}" --region "${AWS_REGION}" >/dev/null
    info "Uploaded probe object: s3://${BUCKET_NAME}/${PROBE_KEY}"
    info "Waiting up to 30s for the event to propagate..."
    FOUND="false"
    for i in $(seq 1 6); do
        sleep 5
        RESULT="$(aws sqs receive-message --queue-url "${QUEUE_URL}" --wait-time-seconds 1 --max-number-of-messages 10 --region "${AWS_REGION}" 2>&1)"
        if echo "${RESULT}" | grep -q "${PROBE_KEY//\//\\/}"; then
            FOUND="true"
            RECEIPT="$(echo "${RESULT}" | jq -r --arg key "${PROBE_KEY}" '.Messages[] | select(.Body | contains($key)) | .ReceiptHandle' | head -1)"
            aws sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${RECEIPT}" --region "${AWS_REGION}" >/dev/null 2>&1
            break
        fi
    done
    if [[ "${FOUND}" == "true" ]]; then
        ok "Probe message arrived in SQS. The S3 -> SNS -> SQS bridge is working end-to-end."
        info "If files still aren't processed, the problem is downstream: check ec2-sqs-poller.service on the EC2 instance itself (see the checklist below)."
    else
        bad "No message arrived in SQS within 30s. The bridge is broken somewhere in steps 1-4 above — check whichever one failed."
    fi
    aws s3 rm "s3://${BUCKET_NAME}/${PROBE_KEY}" --region "${AWS_REGION}" >/dev/null 2>&1
else
    info "Skipped — no valid queue URL from step 3."
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
    echo "Fix the ❌ items above, starting from the lowest-numbered failing step —"
    echo "later steps can't work until earlier ones do."
fi
