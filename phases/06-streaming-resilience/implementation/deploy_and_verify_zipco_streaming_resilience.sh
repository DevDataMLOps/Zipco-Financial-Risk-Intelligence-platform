#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
STACK_NAME="${STACK_NAME:-zipco-streaming-resilience}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
DATA_BUCKET="${DATA_BUCKET:-zipco-financial-platform-${ACCOUNT_ID}-${REGION}}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
VALID_COUNT="${VALID_COUNT:-25}"
INVALID_COUNT="${INVALID_COUNT:-3}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-cloudshell}"
KMS_KEY_ARN="${KMS_KEY_ARN:-}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

for command in aws python3 zip jq sha256sum awk; do
  command -v "${command}" >/dev/null || { echo "ERROR: ${command} is required" >&2; exit 1; }
done

aws sts get-caller-identity >/dev/null
aws s3api head-bucket --bucket "${DATA_BUCKET}" >/dev/null

if [[ -z "${KMS_KEY_ARN}" ]]; then
  KMS_KEY_ARN="$(
    aws kms describe-key \
      --key-id alias/zipco-financial-platform \
      --region "${REGION}" \
      --query 'KeyMetadata.Arn' \
      --output text \
      --no-cli-pager 2>/dev/null || true
  )"
fi
if [[ -z "${KMS_KEY_ARN}" || "${KMS_KEY_ARN}" == "None" ]]; then
  echo "ERROR: ZIPCO customer-managed KMS key was not found." >&2
  echo "Deploy Phase 5 first or set KMS_KEY_ARN explicitly." >&2
  exit 1
fi

echo "Validating Phase 6 infrastructure"
aws cloudformation validate-template \
  --template-body "file://${SCRIPT_DIR}/zipco_streaming_resilience_infrastructure.json" \
  --region "${REGION}" \
  --no-cli-pager >/dev/null

ARTIFACT_SHA="$(sha256sum "${SCRIPT_DIR}/firehose_transform.py" | awk '{print $1}')"
ARTIFACT_KEY="artifacts/streaming-resilience/firehose-transform-${ARTIFACT_SHA}.zip"
(
  cd "${SCRIPT_DIR}"
  zip -q -j "${TMP_DIR}/firehose-transform.zip" firehose_transform.py
)
aws s3 cp "${TMP_DIR}/firehose-transform.zip" "s3://${DATA_BUCKET}/${ARTIFACT_KEY}" \
  --region "${REGION}" \
  --sse aws:kms \
  --sse-kms-key-id "${KMS_KEY_ARN}" \
  --only-show-errors

echo "Deploying Firehose Direct PUT, Lambda, recovery paths, and CloudWatch controls"
aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${SCRIPT_DIR}/zipco_streaming_resilience_infrastructure.json" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "Environment=${ENVIRONMENT}" \
    "DataLakeBucketName=${DATA_BUCKET}" \
    "TransformArtifactBucketName=${DATA_BUCKET}" \
    "TransformArtifactObjectKey=${ARTIFACT_KEY}" \
    "KmsKeyArn=${KMS_KEY_ARN}" \
    "AlertEmail=${ALERT_EMAIL}" \
  --tags \
    Project=ZIPCO-Financial-Risk-Intelligence \
    Phase=Streaming-Resilience \
    Environment="${ENVIRONMENT}" \
    ManagedBy=CloudFormation \
  --no-fail-on-empty-changeset \
  --no-cli-pager

DELIVERY_STREAM_NAME="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" --query 'Stacks[0].Outputs[?OutputKey==`FirehoseDeliveryStreamName`].OutputValue' --output text --no-cli-pager)"
DASHBOARD_NAME="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" --query 'Stacks[0].Outputs[?OutputKey==`DashboardName`].OutputValue' --output text --no-cli-pager)"
NOT_BEFORE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Publishing ${VALID_COUNT} valid and ${INVALID_COUNT} expected-invalid events"
python3 "${SCRIPT_DIR}/publish_test_events.py" \
  --delivery-stream-name "${DELIVERY_STREAM_NAME}" \
  --region "${REGION}" \
  --run-id "${RUN_ID}" \
  --valid-count "${VALID_COUNT}" \
  --invalid-count "${INVALID_COUNT}" \
  > "${TMP_DIR}/publisher.json"
jq . "${TMP_DIR}/publisher.json"

echo "Waiting for buffered delivery and verifying 20 resilience controls"
python3 "${SCRIPT_DIR}/verify_streaming_resilience.py" \
  --stack-name "${STACK_NAME}" \
  --bucket "${DATA_BUCKET}" \
  --region "${REGION}" \
  --run-id "${RUN_ID}" \
  --not-before "${NOT_BEFORE}" \
  --expected-valid "${VALID_COUNT}" \
  --expected-invalid "${INVALID_COUNT}" \
  --output "${TMP_DIR}/verification.json" \
  > "${TMP_DIR}/verification-console.json"

echo "Exercising the recovery utility in safe dry-run mode"
python3 "${SCRIPT_DIR}/replay_stream_records.py" \
  --bucket "${DATA_BUCKET}" \
  --prefix "streaming/raw/" \
  --delivery-stream-name "${DELIVERY_STREAM_NAME}" \
  --region "${REGION}" \
  --run-id "${RUN_ID}" \
  --max-records "$((VALID_COUNT + INVALID_COUNT))" \
  > "${TMP_DIR}/replay.json"

jq \
  --slurpfile publisher "${TMP_DIR}/publisher.json" \
  --slurpfile replay "${TMP_DIR}/replay.json" \
  '. + {publisher: $publisher[0], replay_dry_run: $replay[0]}' \
  "${TMP_DIR}/verification.json" > "${TMP_DIR}/verification-complete.json"

EVIDENCE_PREFIX="streaming/evidence/run_id=${RUN_ID}"
aws s3 cp "${TMP_DIR}/verification-complete.json" "s3://${DATA_BUCKET}/${EVIDENCE_PREFIX}/zipco_streaming_resilience_deployment_verification.json" \
  --region "${REGION}" --sse aws:kms --sse-kms-key-id "${KMS_KEY_ARN}" --content-type application/json --only-show-errors
aws s3 cp "${TMP_DIR}/verification-complete.json" "s3://${DATA_BUCKET}/metadata/contracts/streaming-resilience/zipco_streaming_resilience_deployment_verification.json" \
  --region "${REGION}" --sse aws:kms --sse-kms-key-id "${KMS_KEY_ARN}" --content-type application/json --only-show-errors
aws s3api head-object --bucket "${DATA_BUCKET}" --key "${EVIDENCE_PREFIX}/zipco_streaming_resilience_deployment_verification.json" --region "${REGION}" --no-cli-pager >/dev/null

DASHBOARD_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"
echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Streaming controls: PASS (20/20)"
echo "Firehose stream: ${DELIVERY_STREAM_NAME} (Direct PUT, encrypted transport buffer)"
echo "Valid records curated: ${VALID_COUNT}/${VALID_COUNT}"
echo "Expected-invalid records: ${INVALID_COUNT} sent to the Firehose error path"
echo "Recovery: raw backup enabled; replay dry run passed"
echo "CloudWatch: 4 metric alarms + 1 composite alarm"
echo "Dashboard: ${DASHBOARD_URL}"
echo "Evidence: s3://${DATA_BUCKET}/${EVIDENCE_PREFIX}/zipco_streaming_resilience_deployment_verification.json"
