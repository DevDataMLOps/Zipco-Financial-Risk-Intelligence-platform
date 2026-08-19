#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_PAGER=""

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
ATHENA_WORKGROUP="${ATHENA_WORKGROUP:-zipco-risk-analytics}"
SECURITY_STACK="${SECURITY_STACK:-zipco-security-governance}"
BOOTSTRAP_STACK="${BOOTSTRAP_STACK:-zipco-lake-formation-bootstrap}"
DEMO_STACK="${DEMO_STACK:-zipco-lake-formation-demo}"
DEMO_DATABASE="${DEMO_DATABASE:-zipco_lf_governance_demo}"
DEMO_TABLE="${DEMO_TABLE:-risk_band_summary}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_TEMPLATE="${SCRIPT_DIR}/zipco_lake_formation_bootstrap.json"
DEMO_TEMPLATE="${SCRIPT_DIR}/zipco_lake_formation_demo.json"
CONTRACT_FILE="${SCRIPT_DIR}/lake_formation_demo_contract.json"
VALIDATOR_FILE="${SCRIPT_DIR}/lake_formation_validator.py"
FIXTURE_FILE="${SCRIPT_DIR}/data/risk_band_summary.csv"
OUTPUT_FILE="${SCRIPT_DIR}/zipco_iam_lake_formation_demo_verification.json"
TMP_DIR="$(mktemp -d)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

awsr() {
  aws --region "${REGION}" "$@"
}

recover_failed_stack() {
  local stack_name="$1"
  local state
  state="$(awsr cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
  if [[ "${state}" == "ROLLBACK_COMPLETE" ]]; then
    printf 'Removing exact rolled-back stack %s before retry\n' "${stack_name}"
    awsr cloudformation delete-stack --stack-name "${stack_name}"
    awsr cloudformation wait stack-delete-complete --stack-name "${stack_name}"
  fi
}

catalog_snapshot() {
  local result='{}'
  local database
  local count
  for database in zipco_financial_risk zipco_financial_analytics zipco_financial_risk_engine; do
    if awsr glue get-database --name "${database}" >/dev/null 2>&1; then
      count="$(awsr glue get-tables --database-name "${database}" --query 'length(TableList)' --output text)"
    else
      count=-1
    fi
    result="$(jq --arg database "${database}" --argjson count "${count}" '. + {($database): $count}' <<<"${result}")"
  done
  printf '%s\n' "${result}" | jq -S .
}

require_command aws
require_command jq
require_command sha256sum
require_command zip

for file in "${BOOTSTRAP_TEMPLATE}" "${DEMO_TEMPLATE}" "${CONTRACT_FILE}" "${VALIDATOR_FILE}" "${FIXTURE_FILE}"; do
  [[ -f "${file}" ]] || fail "Missing bundle artifact: ${file}"
done

jq empty "${BOOTSTRAP_TEMPLATE}"
jq empty "${DEMO_TEMPLATE}"
jq empty "${CONTRACT_FILE}"
python3 -m py_compile "${VALIDATOR_FILE}"
awsr cloudformation validate-template --template-body "file://${BOOTSTRAP_TEMPLATE}" >/dev/null
awsr cloudformation validate-template --template-body "file://${DEMO_TEMPLATE}" >/dev/null

IDENTITY_JSON="$(awsr sts get-caller-identity)"
ACCOUNT_ID="$(jq -r '.Account' <<<"${IDENTITY_JSON}")"
CALLER_ARN="$(jq -r '.Arn' <<<"${IDENTITY_JSON}")"
DATA_BUCKET="${DATA_BUCKET_NAME:-zipco-financial-platform-${ACCOUNT_ID}-${REGION}}"

[[ "${REGION}" == "us-east-2" ]] || fail "This portfolio environment is verified in us-east-2; current region is ${REGION}"
awsr s3api head-bucket --bucket "${DATA_BUCKET}" >/dev/null
awsr athena get-work-group --work-group "${ATHENA_WORKGROUP}" >/dev/null

SECURITY_KEY_ARN="$(awsr cloudformation describe-stacks \
  --stack-name "${SECURITY_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityKeyArn'].OutputValue | [0]" \
  --output text)"
[[ -n "${SECURITY_KEY_ARN}" && "${SECURITY_KEY_ARN}" != "None" ]] || fail "SecurityKeyArn was not found in ${SECURITY_STACK}"

DATA_ENGINEER_ROLE="zipco-data-engineer-${ENVIRONMENT}"
RISK_ANALYST_ROLE="zipco-risk-analyst-${ENVIRONMENT}"
DATA_STEWARD_ROLE="zipco-data-steward-${ENVIRONMENT}"
SECURITY_AUDITOR_ROLE="zipco-security-auditor-${ENVIRONMENT}"
for role_name in "${DATA_ENGINEER_ROLE}" "${RISK_ANALYST_ROLE}" "${DATA_STEWARD_ROLE}" "${SECURITY_AUDITOR_ROLE}"; do
  awsr iam get-role --role-name "${role_name}" >/dev/null
done

CATALOG_BEFORE="$(catalog_snapshot)"

printf 'Deploying scoped CloudFormation and Lambda Lake Formation administrators\n'
recover_failed_stack "${BOOTSTRAP_STACK}"
awsr cloudformation deploy \
  --stack-name "${BOOTSTRAP_STACK}" \
  --template-file "${BOOTSTRAP_TEMPLATE}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    Environment="${ENVIRONMENT}" \
    DataBucketName="${DATA_BUCKET}" \
    SecurityKeyArn="${SECURITY_KEY_ARN}" \
    AthenaWorkGroupName="${ATHENA_WORKGROUP}" \
  --no-fail-on-empty-changeset

DEPLOYMENT_ROLE_ARN="$(awsr cloudformation describe-stacks \
  --stack-name "${BOOTSTRAP_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='DeploymentRoleArn'].OutputValue | [0]" \
  --output text)"
VALIDATION_ROLE_ARN="$(awsr cloudformation describe-stacks \
  --stack-name "${BOOTSTRAP_STACK}" \
  --query "Stacks[0].Outputs[?OutputKey=='ValidationRoleArn'].OutputValue | [0]" \
  --output text)"
[[ -n "${DEPLOYMENT_ROLE_ARN}" && "${DEPLOYMENT_ROLE_ARN}" != "None" ]] || fail "Bootstrap did not return the CloudFormation deployment role ARN"
[[ -n "${VALIDATION_ROLE_ARN}" && "${VALIDATION_ROLE_ARN}" != "None" ]] || fail "Bootstrap did not return the validation role ARN"

CONTRACT_SHA256="$(sha256sum "${CONTRACT_FILE}" | awk '{print $1}')"
FIXTURE_SHA256="$(sha256sum "${FIXTURE_FILE}" | awk '{print $1}')"
VALIDATOR_SHA256="$(sha256sum "${VALIDATOR_FILE}" | awk '{print $1}')"
VALIDATOR_CODE_KEY="security-governance/lake-formation-demo/code/${VALIDATOR_SHA256}/lake_formation_validator.zip"
zip -q -j "${TMP_DIR}/lake_formation_validator.zip" "${VALIDATOR_FILE}"

printf 'Uploading encrypted demo fixture and versioned validator code\n'
awsr s3api put-object \
  --bucket "${DATA_BUCKET}" \
  --key "governance-demo/risk_band_summary/part-00000.csv" \
  --body "${FIXTURE_FILE}" \
  --server-side-encryption aws:kms \
  --ssekms-key-id "${SECURITY_KEY_ARN}" \
  --bucket-key-enabled >/dev/null
awsr s3api put-object \
  --bucket "${DATA_BUCKET}" \
  --key "${VALIDATOR_CODE_KEY}" \
  --body "${TMP_DIR}/lake_formation_validator.zip" \
  --server-side-encryption aws:kms \
  --ssekms-key-id "${SECURITY_KEY_ARN}" \
  --bucket-key-enabled >/dev/null

printf 'Deploying the isolated hybrid Lake Formation catalog and LF-TBAC grants\n'
recover_failed_stack "${DEMO_STACK}"
awsr cloudformation deploy \
  --stack-name "${DEMO_STACK}" \
  --template-file "${DEMO_TEMPLATE}" \
  --role-arn "${DEPLOYMENT_ROLE_ARN}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    Environment="${ENVIRONMENT}" \
    DataBucketName="${DATA_BUCKET}" \
    SecurityKeyArn="${SECURITY_KEY_ARN}" \
    AthenaWorkGroupName="${ATHENA_WORKGROUP}" \
    DeploymentRoleArn="${DEPLOYMENT_ROLE_ARN}" \
    ValidationRoleArn="${VALIDATION_ROLE_ARN}" \
    ValidatorCodeBucket="${DATA_BUCKET}" \
    ValidatorCodeKey="${VALIDATOR_CODE_KEY}" \
    DataEngineerRoleName="${DATA_ENGINEER_ROLE}" \
    RiskAnalystRoleName="${RISK_ANALYST_ROLE}" \
    DataStewardRoleName="${DATA_STEWARD_ROLE}" \
    SecurityAuditorRoleName="${SECURITY_AUDITOR_ROLE}" \
    DemoDatabaseName="${DEMO_DATABASE}" \
    DemoTableName="${DEMO_TABLE}" \
  --no-fail-on-empty-changeset

AUTHORIZED_PROBE_ROLE_ARN="$(awsr cloudformation describe-stacks --stack-name "${DEMO_STACK}" --query "Stacks[0].Outputs[?OutputKey=='AuthorizedProbeRoleArn'].OutputValue | [0]" --output text)"
DENIED_PROBE_ROLE_ARN="$(awsr cloudformation describe-stacks --stack-name "${DEMO_STACK}" --query "Stacks[0].Outputs[?OutputKey=='DeniedProbeRoleArn'].OutputValue | [0]" --output text)"
VALIDATION_FUNCTION="$(awsr cloudformation describe-stacks --stack-name "${DEMO_STACK}" --query "Stacks[0].Outputs[?OutputKey=='ValidationFunctionName'].OutputValue | [0]" --output text)"

jq -n \
  --arg validation_role_arn "${VALIDATION_ROLE_ARN}" \
  --arg authorized_probe_role_arn "${AUTHORIZED_PROBE_ROLE_ARN}" \
  --arg denied_probe_role_arn "${DENIED_PROBE_ROLE_ARN}" \
  --arg data_engineer "arn:aws:iam::${ACCOUNT_ID}:role/${DATA_ENGINEER_ROLE}" \
  --arg risk_analyst "arn:aws:iam::${ACCOUNT_ID}:role/${RISK_ANALYST_ROLE}" \
  --arg data_steward "arn:aws:iam::${ACCOUNT_ID}:role/${DATA_STEWARD_ROLE}" \
  --arg security_auditor "arn:aws:iam::${ACCOUNT_ID}:role/${SECURITY_AUDITOR_ROLE}" \
  --arg contract_sha256 "${CONTRACT_SHA256}" \
  --arg fixture_sha256 "${FIXTURE_SHA256}" \
  --arg validator_sha256 "${VALIDATOR_SHA256}" \
  --argjson catalog_before "${CATALOG_BEFORE}" \
  '{
    validation_role_arn:$validation_role_arn,
    authorized_probe_role_arn:$authorized_probe_role_arn,
    denied_probe_role_arn:$denied_probe_role_arn,
    persona_arns:{data_engineer:$data_engineer,risk_analyst:$risk_analyst,data_steward:$data_steward,security_auditor:$security_auditor},
    contract_sha256:$contract_sha256,
    fixture_sha256:$fixture_sha256,
    validator_sha256:$validator_sha256,
    catalog_before:$catalog_before
  }' >"${TMP_DIR}/validation-request.json"

printf 'Executing authorized and expected-denial access probes\n'
aws --region "${REGION}" --cli-read-timeout 360 lambda invoke \
  --function-name "${VALIDATION_FUNCTION}" \
  --cli-binary-format raw-in-base64-out \
  --payload "file://${TMP_DIR}/validation-request.json" \
  "${OUTPUT_FILE}" >"${TMP_DIR}/invoke-metadata.json"

if jq -e '.FunctionError != null' "${TMP_DIR}/invoke-metadata.json" >/dev/null; then
  jq . "${OUTPUT_FILE}" >&2 || true
  fail "Lake Formation validation Lambda returned an error"
fi

jq -e '.status == "DEPLOYED_RUN_AND_VERIFIED"' "${OUTPUT_FILE}" >/dev/null
jq -e '.controls.status == "PASS" and .controls.passed == 18 and .controls.total == 18' "${OUTPUT_FILE}" >/dev/null
jq -e '.personas.mapped == 4 and .personas.hybrid_opt_ins == 12 and .personas.security_auditor_select == false' "${OUTPUT_FILE}" >/dev/null
jq -e '.access_tests.authorized_query.state == "SUCCEEDED" and .access_tests.authorized_query.row_count == 4' "${OUTPUT_FILE}" >/dev/null
jq -e '.access_tests.denied_query.state == "FAILED"' "${OUTPUT_FILE}" >/dev/null
jq -e '.regression_guard.unchanged == true' "${OUTPUT_FILE}" >/dev/null

printf '\nStatus: DEPLOYED_RUN_AND_VERIFIED\n'
printf 'Lake Formation controls: PASS (18/18)\n'
printf 'Registered location: %s (HYBRID)\n' "$(jq -r '.scope.registered_location_arn' "${OUTPUT_FILE}")"
printf 'LF-TBAC tags: zipco-domain=risk-analytics, zipco-sensitivity=internal\n'
printf 'Persona mappings: 4/4\n'
printf 'Hybrid opt-ins: 12/12\n'
printf 'Authorized query: SUCCEEDED\n'
printf 'Metadata-only query: FAILED_AS_EXPECTED\n'
printf 'Existing analytics catalog: UNCHANGED (3/3 databases)\n'
printf 'Lake Formation console: %s\n' "$(jq -r '.lake_formation_console_url' "${OUTPUT_FILE}")"
printf 'Evidence: %s\n' "$(jq -r '.evidence_uri' "${OUTPUT_FILE}")"
printf 'Original caller: %s\n' "${CALLER_ARN}"
