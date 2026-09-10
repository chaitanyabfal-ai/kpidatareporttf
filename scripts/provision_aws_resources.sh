#!/usr/bin/env bash
#
# ILDS AWS Provisioning — single canonical script.
#
# Replaces: provision_all_aws.sh, provision_aws_cli_json.sh,
#           provision_aws_cloud_stack.sh, provision_aws_resources_final.sh,
#           provision_final_working.sh, provision_v7_style.sh,
#           provision_working.sh, fix_pipeline_final.sh
# Delete those after adopting this one — see SECURITY.md / README_CHANGES.md.
#
# Provisions: S3 bucket (+ prefixes) -> SNS topic -> SQS queue, wired
# end-to-end, plus an optional IAM role/instance profile and EC2 instance
# for the KPI poller. Idempotent: safe to re-run.
#
# Usage:
#   ./scripts/provision_aws_resources.sh
#   EC2_LAUNCH=true ALERT_EMAIL=you@example.com ./scripts/provision_aws_resources.sh
#
set -euo pipefail

# --------------------------------------------------------------------------
# Configuration (override via environment variables)
# --------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-ap-south-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${BUCKET_NAME:-${ACCOUNT_ID}-ilds-sensor-data}"
QUEUE_NAME="${QUEUE_NAME:-ilds_queue_1}"
SNS_S3_TOPIC_NAME="${SNS_S3_TOPIC_NAME:-ilds-s3-events}"
SNS_ALERT_TOPIC_NAME="${SNS_ALERT_TOPIC_NAME:-ilds-alerts}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

# Sensor prefixes actually used by scripts/s3_uploader.py (build_s3_key) —
# keep this in sync with SENSOR_PREFIXES in config/aws_config.py.
BFA_PREFIXES=("BFA3/" "BFA8/" "BFA12/")

# EC2 (optional)
EC2_LAUNCH="${EC2_LAUNCH:-false}"
EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-t3.micro}"
EC2_KEY_NAME="${EC2_KEY_NAME:-}"          # leave empty to launch without SSH key access (use SSM instead)
EC2_SECURITY_GROUP_NAME="${EC2_SECURITY_GROUP_NAME:-ilds-kpi-sg}"
EC2_ROLE_NAME="${EC2_ROLE_NAME:-ilds-ec2-role}"
EC2_INSTANCE_PROFILE_NAME="${EC2_INSTANCE_PROFILE_NAME:-ilds-ec2-profile}"
REPO_URL="${REPO_URL:-https://github.com/chaitanyabfal-ai/kpidatareporttf.git}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"     # must match systemd/*.service User=

echo "=== ILDS AWS Provisioning ==="
echo "Account: ${ACCOUNT_ID} | Region: ${AWS_REGION} | Bucket: ${BUCKET_NAME}"

for cmd in aws jq; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: required command '${cmd}' not found on PATH." >&2
        exit 1
    fi
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# --------------------------------------------------------------------------
# 1) S3 bucket
# --------------------------------------------------------------------------
if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
    echo "S3 bucket already exists: ${BUCKET_NAME}"
else
    echo "Creating S3 bucket: ${BUCKET_NAME}"
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}"
    else
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}" \
            --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
    fi
fi

aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

for prefix in "${BFA_PREFIXES[@]}"; do
    if ! aws s3api head-object --bucket "${BUCKET_NAME}" --key "${prefix}" --region "${AWS_REGION}" 2>/dev/null; then
        aws s3api put-object --bucket "${BUCKET_NAME}" --key "${prefix}" --region "${AWS_REGION}" >/dev/null
        echo "Created prefix: s3://${BUCKET_NAME}/${prefix}"
    fi
done

# --------------------------------------------------------------------------
# 2) SNS topic for S3 events
# --------------------------------------------------------------------------
SNS_TOPIC_ARN="$(aws sns create-topic --name "${SNS_S3_TOPIC_NAME}" --region "${AWS_REGION}" --query TopicArn --output text)"
echo "SNS topic: ${SNS_TOPIC_ARN}"

jq -n --arg region "${AWS_REGION}" --arg account "${ACCOUNT_ID}" \
      --arg topic "${SNS_TOPIC_ARN}" --arg bucket "${BUCKET_NAME}" '
{
  Version: "2012-10-17",
  Statement: [{
    Sid: "AllowS3Publish",
    Effect: "Allow",
    Principal: {Service: "s3.amazonaws.com"},
    Action: "sns:Publish",
    Resource: $topic,
    Condition: {ArnLike: {"aws:SourceArn": ("arn:aws:s3:::" + $bucket)}}
  }]
}' > "${TMP_DIR}/sns_topic_policy.json"

aws sns set-topic-attributes \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --attribute-name Policy \
    --attribute-value "$(jq -c . "${TMP_DIR}/sns_topic_policy.json")" \
    --region "${AWS_REGION}"

# Optional alert topic with an email subscription
ALERT_TOPIC_ARN=""
if [[ -n "${ALERT_EMAIL}" ]]; then
    ALERT_TOPIC_ARN="$(aws sns create-topic --name "${SNS_ALERT_TOPIC_NAME}" --region "${AWS_REGION}" --query TopicArn --output text)"
    aws sns subscribe \
        --topic-arn "${ALERT_TOPIC_ARN}" \
        --protocol email \
        --notification-endpoint "${ALERT_EMAIL}" \
        --region "${AWS_REGION}" > /dev/null
    echo "Alert topic: ${ALERT_TOPIC_ARN} (confirm the subscription email sent to ${ALERT_EMAIL})"
fi

# --------------------------------------------------------------------------
# 3) SQS queue, wired to SNS
# --------------------------------------------------------------------------
SQS_QUEUE_URL="$(aws sqs create-queue \
    --queue-name "${QUEUE_NAME}" \
    --attributes VisibilityTimeout=30,MessageRetentionPeriod=345600,ReceiveMessageWaitTimeSeconds=20 \
    --region "${AWS_REGION}" --query QueueUrl --output text)"
SQS_QUEUE_ARN="$(aws sqs get-queue-attributes \
    --queue-url "${SQS_QUEUE_URL}" --attribute-names QueueArn \
    --region "${AWS_REGION}" --query Attributes.QueueArn --output text)"
echo "SQS queue: ${SQS_QUEUE_URL}"

jq -n --arg queue "${SQS_QUEUE_ARN}" --arg topic "${SNS_TOPIC_ARN}" '
{
  Version: "2012-10-17",
  Statement: [{
    Sid: "AllowSNSSendMessage",
    Effect: "Allow",
    Principal: {Service: "sns.amazonaws.com"},
    Action: "sqs:SendMessage",
    Resource: $queue,
    Condition: {ArnEquals: {"aws:SourceArn": $topic}}
  }]
}' > "${TMP_DIR}/sqs_policy.json"

jq -n --arg policy "$(jq -c . "${TMP_DIR}/sqs_policy.json")" '{Policy: $policy}' \
    > "${TMP_DIR}/sqs_attrs.json"

aws sqs set-queue-attributes \
    --queue-url "${SQS_QUEUE_URL}" \
    --attributes "file://${TMP_DIR}/sqs_attrs.json" \
    --region "${AWS_REGION}"

aws sns subscribe \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --protocol sqs \
    --notification-endpoint "${SQS_QUEUE_ARN}" \
    --attributes RawMessageDelivery=false \
    --region "${AWS_REGION}" > /dev/null

# --------------------------------------------------------------------------
# 4) S3 -> SNS event notification
# --------------------------------------------------------------------------
jq -n --arg topic "${SNS_TOPIC_ARN}" '
{TopicConfigurations: [{TopicArn: $topic, Events: ["s3:ObjectCreated:*"]}]}' \
    > "${TMP_DIR}/s3_notification.json"

aws s3api put-bucket-notification-configuration \
    --bucket "${BUCKET_NAME}" \
    --notification-configuration "file://${TMP_DIR}/s3_notification.json" \
    --region "${AWS_REGION}"
echo "S3 -> SNS -> SQS pipeline wired."

# --------------------------------------------------------------------------
# 5) IAM role + instance profile for EC2 (keyless auth — no static keys)
# --------------------------------------------------------------------------
jq -n --arg bucket "${BUCKET_NAME}" --arg queue "${SQS_QUEUE_ARN}" --arg topic "${SNS_TOPIC_ARN}" '
{
  Version: "2012-10-17",
  Statement: [
    {Effect: "Allow", Action: ["s3:ListBucket","s3:GetObject","s3:PutObject","s3:DeleteObject"],
     Resource: [("arn:aws:s3:::" + $bucket), ("arn:aws:s3:::" + $bucket + "/*")]},
    {Effect: "Allow", Action: ["sqs:GetQueueUrl","sqs:GetQueueAttributes","sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage"],
     Resource: $queue},
    {Effect: "Allow", Action: ["sns:Publish","sns:Subscribe"], Resource: $topic}
  ]
}' > "${TMP_DIR}/ec2_policy.json"

TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if ! aws iam get-role --role-name "${EC2_ROLE_NAME}" >/dev/null 2>&1; then
    aws iam create-role --role-name "${EC2_ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" > /dev/null
    echo "Created IAM role: ${EC2_ROLE_NAME}"
fi

aws iam put-role-policy \
    --role-name "${EC2_ROLE_NAME}" \
    --policy-name "ilds-ec2-inline-policy" \
    --policy-document "file://${TMP_DIR}/ec2_policy.json"

if ! aws iam get-instance-profile --instance-profile-name "${EC2_INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "${EC2_INSTANCE_PROFILE_NAME}" > /dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "${EC2_INSTANCE_PROFILE_NAME}" \
        --role-name "${EC2_ROLE_NAME}"
    echo "Created instance profile: ${EC2_INSTANCE_PROFILE_NAME}"
    echo "Waiting for instance profile propagation..."
    sleep 10
fi

# --------------------------------------------------------------------------
# 6) Optional: launch EC2 worker
# --------------------------------------------------------------------------
if [[ "${EC2_LAUNCH}" == "true" ]]; then
    echo "Launching EC2 instance..."

    VPC_ID="$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}")"

    SG_ID="$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${EC2_SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
    if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
        SG_ID="$(aws ec2 create-security-group \
            --group-name "${EC2_SECURITY_GROUP_NAME}" \
            --description "ILDS KPI runner" \
            --vpc-id "${VPC_ID}" --region "${AWS_REGION}" \
            --query GroupId --output text)"
        # NOTE: 0.0.0.0/0 SSH is convenient but broad. Prefer SSM Session Manager
        # (needs no open port) or restrict --cidr to your office/VPN IP.
        aws ec2 authorize-security-group-ingress \
            --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 \
            --region "${AWS_REGION}" >/dev/null 2>&1 || true
    fi

    SUBNET_ID="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'Subnets[0].SubnetId' --output text --region "${AWS_REGION}")"

    EC2_AMI_ID="$(aws ssm get-parameters \
        --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
        --query 'Parameters[0].Value' --output text --region "${AWS_REGION}")"

    cat > "${TMP_DIR}/user_data.sh" <<USERDATA
#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y git python3 python3-pip python3-devel gcc

useradd -m ${DEPLOY_USER} || true
su - ${DEPLOY_USER} -c "
  cd /home/${DEPLOY_USER}
  if [ ! -d ilds_s3_garage_uploader_project ]; then
    git clone ${REPO_URL} ilds_s3_garage_uploader_project
  fi
  cd ilds_s3_garage_uploader_project
    python3 -m venv kpidatatf
    source kpidatatf/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
  mkdir -p data/incoming_csvs data/garage_kpi_downloads data/kpi_reports data/logs
  cat > .env <<'ENVEOF'
AWS_REGION=${AWS_REGION}
S3_BUCKET=${BUCKET_NAME}
SQS_QUEUE_URL=${SQS_QUEUE_URL}
WATCH_DIRECTORY=./data/incoming_csvs
GARAGE_ENDPOINT_URL=http://100.78.2.20:3900
GARAGE_S3_BUCKET=data
GARAGE_ACCESS_KEY_ID=REPLACE_ME
GARAGE_SECRET_ACCESS_KEY=REPLACE_ME
ENVEOF
"
# GARAGE_* credentials are placeholders — this instance can't reach Garage
# over Tailscale by default anyway. Set real values via SSM Parameter Store
# or by editing .env after connecting (see SECURITY.md), then install the
# systemd units from systemd/ and enable them.
cp /home/${DEPLOY_USER}/ilds_s3_garage_uploader_project/systemd/garage-sync.service /etc/systemd/system/
cp /home/${DEPLOY_USER}/ilds_s3_garage_uploader_project/systemd/ec2-sqs-poller.service /etc/systemd/system/
cp /home/${DEPLOY_USER}/ilds_s3_garage_uploader_project/systemd/ilds-kpi-dashboard.service /etc/systemd/system/
cp /home/${DEPLOY_USER}/ilds_s3_garage_uploader_project/systemd/ilds-kpi-aggregator.service /etc/systemd/system/
cp /home/${DEPLOY_USER}/ilds_s3_garage_uploader_project/systemd/ilds-kpi-aggregator.timer /etc/systemd/system/
sed -i "s#ec2-user#${DEPLOY_USER}#g" /etc/systemd/system/garage-sync.service /etc/systemd/system/ec2-sqs-poller.service /etc/systemd/system/ilds-kpi-dashboard.service
sed -i "s#ec2-user#${DEPLOY_USER}#g" /etc/systemd/system/ilds-kpi-aggregator.service
chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/ilds_s3_garage_uploader_project
systemctl daemon-reload
systemctl enable --now garage-sync ec2-sqs-poller ilds-kpi-dashboard
systemctl enable --now ilds-kpi-aggregator.timer
USERDATA

    INSTANCE_ID="$(aws ec2 run-instances \
        --image-id "${EC2_AMI_ID}" \
        --count 1 \
        --instance-type "${EC2_INSTANCE_TYPE}" \
        ${EC2_KEY_NAME:+--key-name "${EC2_KEY_NAME}"} \
        --security-group-ids "${SG_ID}" \
        --subnet-id "${SUBNET_ID}" \
        --iam-instance-profile "Name=${EC2_INSTANCE_PROFILE_NAME}" \
        --region "${AWS_REGION}" \
        --user-data "file://${TMP_DIR}/user_data.sh" \
        --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3}' \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ilds-garage-kpi-runner}]' \
        --query 'Instances[0].InstanceId' --output text)"

    echo "Launched EC2 instance: ${INSTANCE_ID}"
    aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
    echo "Public IP: ${PUBLIC_IP}"
    if [[ -n "${EC2_KEY_NAME}" ]]; then
        echo "SSH:       ssh -i ${EC2_KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
    else
        echo "No key pair set (EC2_KEY_NAME empty) — connect via SSM: aws ssm start-session --target ${INSTANCE_ID}"
    fi
else
    echo "EC2 launch skipped. Set EC2_LAUNCH=true to provision the worker instance."
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Provisioning Summary ==="
echo "Bucket:         s3://${BUCKET_NAME}"
echo "SNS topic:      ${SNS_TOPIC_ARN}"
echo "SQS queue:      ${SQS_QUEUE_URL}"
[[ -n "${ALERT_TOPIC_ARN}" ]] && echo "Alert topic:    ${ALERT_TOPIC_ARN}"
echo "IAM role:       ${EC2_ROLE_NAME}"
echo "Instance prof.: ${EC2_INSTANCE_PROFILE_NAME}"
echo ""
echo "Update .env with:"
echo "  S3_BUCKET=${BUCKET_NAME}"
echo "  SQS_QUEUE_URL=${SQS_QUEUE_URL}"
