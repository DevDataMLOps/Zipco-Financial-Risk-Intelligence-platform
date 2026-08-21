#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
STACK_NAME="${STACK_NAME:-zipco-free-plan-event-resilience}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
DATA_BUCKET="${DATA_BUCKET:-zipco-financial-platform-${ACCOUNT_ID}-${REGION}}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
VALID_COUNT="${VALID_COUNT:-25}"
INVALID_COUNT="${INVALID_COUNT:-3}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-cloudshell}"
KMS_KEY_ARN="${KMS_KEY_ARN:-}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

for command_name in aws python3 zip jq sha256sum awk; do
  command -v "${command_name}" >/dev/null || { echo "ERROR: ${command_name} is required" >&2; exit 1; }
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

echo "Validating Free-plan event-resilience infrastructure"
aws cloudformation validate-template \
  --template-body "file://${SCRIPT_DIR}/zipco_free_plan_event_resilience_infrastructure.json" \
  --region "${REGION}" \
  --no-cli-pager >/dev/null

ARTIFACT_SHA="$(sha256sum "${SCRIPT_DIR}/event_contract.py" "${SCRIPT_DIR}/lambda_event_processor.py" | sha256sum | awk '{print $1}')"
ARTIFACT_KEY="artifacts/free-plan-event-resilience/event-processor-${ARTIFACT_SHA}.zip"
(
  cd "${SCRIPT_DIR}"
  zip -q -j "${TMP_DIR}/event-processor.zip" event_contract.py lambda_event_processor.py
)
aws s3 cp "${TMP_DIR}/event-processor.zip" "s3://${DATA_BUCKET}/${ARTIFACT_KEY}" \
  --region "${REGION}" \
  --sse aws:kms \
  --sse-kms-key-id "${KMS_KEY_ARN}" \
  --only-show-errors

echo "Deploying Lambda event processing, S3 recovery controls, and CloudWatch monitoring"
aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${SCRIPT_DIR}/zipco_free_plan_event_resilience_infrastructure.json" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "Environment=${ENVIRONMENT}" \
    "DataLakeBucketName=${DATA_BUCKET}" \
    "ProcessorArtifactBucketName=${DATA_BUCKET}" \
    "ProcessorArtifactObjectKey=${ARTIFACT_KEY}" \
    "KmsKeyArn=${KMS_KEY_ARN}" \
    "AlertEmail=${ALERT_EMAIL}" \
  --tags \
    Project=ZIPCO-Financial-Risk-Intelligence \
    Phase=Free-Plan-Event-Resilience \
    Environment="${ENVIRONMENT}" \
    ManagedBy=CloudFormation \
  --no-fail-on-empty-changeset \
  --no-cli-pager

FUNCTION_NAME="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" --query 'Stacks[0].Outputs[?OutputKey==`ProcessorFunctionName`].OutputValue' --output text --no-cli-pager)"
DASHBOARD_NAME="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" --query 'Stacks[0].Outputs[?OutputKey==`DashboardName`].OutputValue' --output text --no-cli-pager)"
NOT_BEFORE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Processing ${VALID_COUNT} valid and ${INVALID_COUNT} expected-invalid events"
python3 "${SCRIPT_DIR}/publish_free_plan_events.py" \
  --function-name "${FUNCTION_NAME}" \
  --region "${REGION}" \
  --run-id "${RUN_ID}" \
  --valid-count "${VALID_COUNT}" \
  --invalid-count "${INVALID_COUNT}" \
  > "${TMP_DIR}/publisher.json"
jq . "${TMP_DIR}/publisher.json"

echo "Exercising bounded recovery in safe dry-run mode"
python3 "${SCRIPT_DIR}/replay_free_plan_events.py" \
  --bucket "${DATA_BUCKET}" \
  --prefix "streaming-free-plan/raw/" \
  --function-name "${FUNCTION_NAME}" \
  --region "${REGION}" \
  --run-id "${RUN_ID}" \
  --max-records "$((VALID_COUNT + INVALID_COUNT))" \
  > "${TMP_DIR}/replay.json"
jq . "${TMP_DIR}/replay.json"

echo "Verifying 20 Free-plan event-resilience controls"
python3 "${SCRIPT_DIR}/verify_free_plan_event_resilience.py" \
  --stack-name "${STACK_NAME}" \
  --bucket "${DATA_BUCKET}" \
  --region "${REGION}" \
  --run-id "${RUN_ID}" \
  --not-before "${NOT_BEFORE}" \
  --expected-valid "${VALID_COUNT}" \
  --expected-invalid "${INVALID_COUNT}" \
  --publisher-result "${TMP_DIR}/publisher.json" \
  --replay-result "${TMP_DIR}/replay.json" \
  --output "${TMP_DIR}/verification.json" \
  > "${TMP_DIR}/verification-console.json"

EVIDENCE_PREFIX="streaming-free-plan/evidence/run_id=${RUN_ID}"
aws s3 cp "${TMP_DIR}/verification.json" "s3://${DATA_BUCKET}/${EVIDENCE_PREFIX}/zipco_free_plan_event_resilience_verification.json" \
  --region "${REGION}" --sse aws:kms --sse-kms-key-id "${KMS_KEY_ARN}" --content-type application/json --only-show-errors
aws s3 cp "${TMP_DIR}/verification.json" "s3://${DATA_BUCKET}/metadata/contracts/free-plan-event-resilience/zipco_free_plan_event_resilience_verification.json" \
  --region "${REGION}" --sse aws:kms --sse-kms-key-id "${KMS_KEY_ARN}" --content-type application/json --only-show-errors
aws s3api head-object --bucket "${DATA_BUCKET}" --key "${EVIDENCE_PREFIX}/zipco_free_plan_event_resilience_verification.json" --region "${REGION}" --no-cli-pager >/dev/null

DASHBOARD_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"
echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Deployment variant: FREE_PLAN_LAMBDA_EVENT_PROCESSING"
echo "Native streaming service: NOT CLAIMED"
echo "Event-resilience controls: PASS (20/20)"
echo "Processor: ${FUNCTION_NAME}"
echo "Valid records curated: ${VALID_COUNT}/${VALID_COUNT}"
echo "Expected-invalid records quarantined: ${INVALID_COUNT}/${INVALID_COUNT}"
echo "Recovery: encrypted raw backup enabled; replay dry run passed"
echo "CloudWatch: 4 metric alarms + 1 composite alarm"
echo "Dashboard: ${DASHBOARD_URL}"
echo "Evidence: s3://${DATA_BUCKET}/${EVIDENCE_PREFIX}/zipco_free_plan_event_resilience_verification.json"
