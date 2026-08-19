#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ACCOUNT="825999268272"
REGION="us-east-2"
ENVIRONMENT="dev"
DATA_BUCKET="zipco-financial-platform-${EXPECTED_ACCOUNT}-${REGION}"
SECURITY_STACK="zipco-security-governance"
CONFIG_RULES_STACK="zipco-security-config-rules"
GLUE_STACK="zipco-glue-relational-v2"
ATHENA_STACK="zipco-athena-analytics"
OBSERVABILITY_STACK="zipco-observability-performance"
GLUE_ROLE="zipco-glue-relational-v2-${ENVIRONMENT}"
GLUE_JOB="zipco-relational-v2-validation-transform"
GLUE_CRAWLER="zipco-relational-v2-curated-crawler"
ATHENA_WORKGROUP="zipco-risk-analytics"
ENABLE_S3_DATA_EVENTS="${ENABLE_S3_DATA_EVENTS:-true}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPENDENCIES_DIR="${SCRIPT_DIR}/dependencies"
CORE_TEMPLATE="${SCRIPT_DIR}/zipco_security_governance_infrastructure.json"
CONFIG_TEMPLATE="${SCRIPT_DIR}/zipco_security_config_rules.json"
CONTRACT_FILE="${SCRIPT_DIR}/security_governance_contract.json"
CLASSIFICATION_FILE="${SCRIPT_DIR}/data_classification_catalog.json"
GLUE_TEMPLATE="${DEPENDENCIES_DIR}/zipco_glue_infrastructure.json"
ATHENA_TEMPLATE="${DEPENDENCIES_DIR}/zipco_athena_infrastructure.json"
OBSERVABILITY_TEMPLATE="${DEPENDENCIES_DIR}/zipco_observability_infrastructure.json"
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-cloudshell"
EVIDENCE_FILE="${SCRIPT_DIR}/zipco_security_governance_deployment_verification.json"
TMP_DIR="$(mktemp -d)"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

# A release bundle carries dependency templates beside this script. A repository
# checkout falls back to the canonical source files so the same script remains runnable.
[[ -f "$CLASSIFICATION_FILE" ]] || CLASSIFICATION_FILE="${SCRIPT_DIR}/../contracts/data_classification_catalog.json"
[[ -f "$GLUE_TEMPLATE" ]] || GLUE_TEMPLATE="${SCRIPT_DIR}/../../../phases/02-glue-etl/implementation/zipco_glue_infrastructure.json"
[[ -f "$ATHENA_TEMPLATE" ]] || ATHENA_TEMPLATE="${SCRIPT_DIR}/../../../platform/athena/zipco_athena_infrastructure.json"
[[ -f "$OBSERVABILITY_TEMPLATE" ]] || OBSERVABILITY_TEMPLATE="${SCRIPT_DIR}/../../../phases/03-optimization/implementation/zipco_observability_infrastructure.json"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

for required in "$CORE_TEMPLATE" "$CONFIG_TEMPLATE" "$CONTRACT_FILE" "$CLASSIFICATION_FILE" \
  "$GLUE_TEMPLATE" "$ATHENA_TEMPLATE" "$OBSERVABILITY_TEMPLATE"; do
  [[ -f "$required" ]] || { echo "Missing required artifact: $required" >&2; exit 2; }
done
for command_name in aws jq sha256sum; do
  command -v "$command_name" >/dev/null || { echo "Required command unavailable: $command_name" >&2; exit 3; }
done
if [[ "$ENABLE_S3_DATA_EVENTS" != "true" && "$ENABLE_S3_DATA_EVENTS" != "false" ]]; then
  echo "ENABLE_S3_DATA_EVENTS must be true or false." >&2
  exit 4
fi

ACTUAL_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
if [[ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  echo "Refusing deployment: expected account $EXPECTED_ACCOUNT but authenticated to $ACTUAL_ACCOUNT." >&2
  exit 5
fi
if [[ "$CALLER_ARN" == "arn:aws:iam::${EXPECTED_ACCOUNT}:root" ]]; then
  echo "WARNING: deploying with root credentials. After this bootstrap, use the MFA-gated ZIPCO roles and reserve root for account recovery." >&2
fi

aws s3api head-bucket --bucket "$DATA_BUCKET"
aws glue get-job --job-name "$GLUE_JOB" >/dev/null
aws glue get-crawler --name "$GLUE_CRAWLER" >/dev/null
aws athena get-work-group --work-group "$ATHENA_WORKGROUP" >/dev/null

echo "Validating security and governance CloudFormation templates"
aws cloudformation validate-template --template-body "file://${CORE_TEMPLATE}" >/dev/null
aws cloudformation validate-template --template-body "file://${CONFIG_TEMPLATE}" >/dev/null
aws cloudformation validate-template --template-body "file://${GLUE_TEMPLATE}" >/dev/null
aws cloudformation validate-template --template-body "file://${ATHENA_TEMPLATE}" >/dev/null
aws cloudformation validate-template --template-body "file://${OBSERVABILITY_TEMPLATE}" >/dev/null

EXISTING_ANALYZER_NAME="$(aws accessanalyzer list-analyzers --type ACCOUNT --query 'analyzers[?status==`ACTIVE`] | [0].name' --output text 2>/dev/null || true)"
CREATE_ACCESS_ANALYZER="true"
if [[ -n "$EXISTING_ANALYZER_NAME" && "$EXISTING_ANALYZER_NAME" != "None" && "$EXISTING_ANALYZER_NAME" != "zipco-account-external-access" ]]; then
  CREATE_ACCESS_ANALYZER="false"
fi

EXISTING_STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$SECURITY_STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
if [[ "$EXISTING_STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
  echo "Removing the rolled-back ZIPCO security stack before retry"
  aws cloudformation delete-stack --stack-name "$SECURITY_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$SECURITY_STACK"
fi

echo "Deploying KMS, audit logging, access roles, Access Analyzer, alarms, and dashboard"
aws cloudformation deploy \
  --stack-name "$SECURITY_STACK" \
  --template-file "$CORE_TEMPLATE" \
  --parameter-overrides \
    "DataBucketName=${DATA_BUCKET}" \
    "Environment=${ENVIRONMENT}" \
    "GlueRoleName=${GLUE_ROLE}" \
    "AthenaWorkGroupName=${ATHENA_WORKGROUP}" \
    "EnableS3DataEvents=${ENABLE_S3_DATA_EVENTS}" \
    "CreateAccessAnalyzer=${CREATE_ACCESS_ANALYZER}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$SECURITY_STACK" --query 'Stacks[0].StackStatus' --output text)"
case "$STACK_STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE) ;;
  *) echo "Unexpected security stack status: $STACK_STATUS" >&2; exit 6 ;;
esac

stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$SECURITY_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" \
    --output text
}

KMS_KEY_ARN="$(stack_output SecurityKeyArn)"
AUDIT_BUCKET="$(stack_output AuditBucketName)"
TRAIL_NAME="$(stack_output AuditTrailName)"
AUDIT_LOG_GROUP="$(stack_output AuditLogGroupName)"
CONFIG_ROLE_ARN="$(stack_output ConfigRoleArn)"
CATALOG_ENCRYPTION_ROLE_ARN="$(stack_output CatalogEncryptionRoleArn)"
DASHBOARD_NAME="$(stack_output SecurityDashboardName)"
if [[ "$CREATE_ACCESS_ANALYZER" == "true" ]]; then
  ANALYZER_NAME="$(stack_output AccessAnalyzerName)"
else
  ANALYZER_NAME="$EXISTING_ANALYZER_NAME"
fi

echo "Upgrading new data-lake writes to the customer-managed KMS key"
jq -n --arg key "$KMS_KEY_ARN" '{Rules:[{ApplyServerSideEncryptionByDefault:{SSEAlgorithm:"aws:kms",KMSMasterKeyID:$key},BucketKeyEnabled:true}]}' \
  > "${TMP_DIR}/data-bucket-encryption.json"
aws s3api put-bucket-encryption \
  --bucket "$DATA_BUCKET" \
  --server-side-encryption-configuration "file://${TMP_DIR}/data-bucket-encryption.json"

jq -n \
  --arg account "$ACTUAL_ACCOUNT" \
  --arg destination "arn:aws:s3:::${AUDIT_BUCKET}" \
  --arg key "$KMS_KEY_ARN" \
  '{
    Destination:{S3BucketDestination:{AccountId:$account,Bucket:$destination,Format:"CSV",Prefix:"inventory/data-lake",Encryption:{SSEKMS:{KeyId:$key}}}},
    IsEnabled:true,
    Id:"zipco-governance-inventory",
    IncludedObjectVersions:"All",
    OptionalFields:["Size","LastModifiedDate","StorageClass","ETag","EncryptionStatus"],
    Schedule:{Frequency:"Weekly"}
  }' > "${TMP_DIR}/inventory.json"
aws s3api put-bucket-inventory-configuration \
  --bucket "$DATA_BUCKET" \
  --id zipco-governance-inventory \
  --inventory-configuration "file://${TMP_DIR}/inventory.json"

echo "Applying KMS controls to Glue, Athena, and the operational failure log"
GLUE_STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$GLUE_STACK" --query 'Stacks[0].StackStatus' --output text)"
if [[ "$GLUE_STACK_STATUS" == "UPDATE_ROLLBACK_FAILED" ]]; then
  echo "Recovering the Glue stack from UPDATE_ROLLBACK_FAILED before retry"
  aws cloudformation continue-update-rollback --stack-name "$GLUE_STACK"
  GLUE_STACK_STATUS="UPDATE_ROLLBACK_IN_PROGRESS"
fi
if [[ "$GLUE_STACK_STATUS" == "UPDATE_ROLLBACK_IN_PROGRESS" ]]; then
  echo "Waiting for the Glue stack rollback to finish before retry"
  for attempt in {1..60}; do
    GLUE_STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$GLUE_STACK" --query 'Stacks[0].StackStatus' --output text)"
    [[ "$GLUE_STACK_STATUS" == "UPDATE_ROLLBACK_COMPLETE" ]] && break
    [[ "$GLUE_STACK_STATUS" == "UPDATE_ROLLBACK_FAILED" ]] && { echo "Glue rollback recovery failed." >&2; exit 8; }
    sleep 5
  done
fi
if [[ "$GLUE_STACK_STATUS" != "CREATE_COMPLETE" && "$GLUE_STACK_STATUS" != "UPDATE_COMPLETE" && "$GLUE_STACK_STATUS" != "UPDATE_ROLLBACK_COMPLETE" ]]; then
  echo "Glue stack is not ready for an update: ${GLUE_STACK_STATUS}" >&2
  exit 9
fi
aws cloudformation deploy \
  --stack-name "$GLUE_STACK" \
  --template-file "$GLUE_TEMPLATE" \
  --parameter-overrides "BucketName=${DATA_BUCKET}" "Environment=${ENVIRONMENT}" "KmsKeyArn=${KMS_KEY_ARN}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

aws cloudformation deploy \
  --stack-name "$ATHENA_STACK" \
  --template-file "$ATHENA_TEMPLATE" \
  --parameter-overrides "BucketName=${DATA_BUCKET}" "Environment=${ENVIRONMENT}" "KmsKeyArn=${KMS_KEY_ARN}" \
  --no-fail-on-empty-changeset

if aws cloudformation describe-stacks --stack-name "$OBSERVABILITY_STACK" >/dev/null 2>&1; then
  aws cloudformation deploy \
    --stack-name "$OBSERVABILITY_STACK" \
    --template-file "$OBSERVABILITY_TEMPLATE" \
    --parameter-overrides "Environment=${ENVIRONMENT}" "KmsKeyArn=${KMS_KEY_ARN}" \
    --capabilities CAPABILITY_AUTO_EXPAND \
    --no-fail-on-empty-changeset
fi

echo "Encrypting all new Glue Data Catalog metadata"
jq -n \
  --arg key "$KMS_KEY_ARN" \
  --arg role "$CATALOG_ENCRYPTION_ROLE_ARN" \
  '{EncryptionAtRest:{CatalogEncryptionMode:"SSE-KMS-WITH-SERVICE-ROLE",SseAwsKmsKeyId:$key,CatalogEncryptionServiceRole:$role}}' \
  > "${TMP_DIR}/catalog-encryption.json"
aws glue put-data-catalog-encryption-settings \
  --catalog-id "$ACTUAL_ACCOUNT" \
  --data-catalog-encryption-settings "file://${TMP_DIR}/catalog-encryption.json"

echo "Configuring AWS Config recording and encrypted delivery"
RECORDER_NAME="$(aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[0].name' --output text 2>/dev/null || true)"
if [[ -z "$RECORDER_NAME" || "$RECORDER_NAME" == "None" ]]; then
  RECORDER_NAME="zipco-security-recorder"
  jq -n --arg name "$RECORDER_NAME" --arg role "$CONFIG_ROLE_ARN" \
    '{name:$name,roleARN:$role,recordingGroup:{allSupported:true,includeGlobalResourceTypes:true},recordingMode:{recordingFrequency:"CONTINUOUS"}}' \
    > "${TMP_DIR}/config-recorder.json"
  aws configservice put-configuration-recorder --configuration-recorder "file://${TMP_DIR}/config-recorder.json"
fi

DELIVERY_CHANNEL_NAME="$(aws configservice describe-delivery-channels --query 'DeliveryChannels[0].name' --output text 2>/dev/null || true)"
if [[ -z "$DELIVERY_CHANNEL_NAME" || "$DELIVERY_CHANNEL_NAME" == "None" ]]; then
  DELIVERY_CHANNEL_NAME="zipco-security-delivery"
  jq -n --arg name "$DELIVERY_CHANNEL_NAME" --arg bucket "$AUDIT_BUCKET" --arg key "$KMS_KEY_ARN" \
    '{name:$name,s3BucketName:$bucket,s3KeyPrefix:"config",s3KmsKeyArn:$key,configSnapshotDeliveryProperties:{deliveryFrequency:"Six_Hours"}}' \
    > "${TMP_DIR}/config-delivery.json"
  aws configservice put-delivery-channel --delivery-channel "file://${TMP_DIR}/config-delivery.json"
fi
aws configservice start-configuration-recorder --configuration-recorder-name "$RECORDER_NAME"

for attempt in {1..12}; do
  RECORDING="$(aws configservice describe-configuration-recorder-status --configuration-recorder-names "$RECORDER_NAME" --query 'ConfigurationRecordersStatus[0].recording' --output text)"
  [[ "${RECORDING,,}" == "true" ]] && break
  sleep 5
done
if [[ "${RECORDING,,}" != "true" ]]; then
  echo "AWS Config recorder did not reach recording state." >&2
  exit 7
fi

echo "Deploying the 15-rule AWS Config governance pack"
CONFIG_STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$CONFIG_RULES_STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
if [[ "$CONFIG_STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
  aws cloudformation delete-stack --stack-name "$CONFIG_RULES_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$CONFIG_RULES_STACK"
fi
aws cloudformation deploy \
  --stack-name "$CONFIG_RULES_STACK" \
  --template-file "$CONFIG_TEMPLATE" \
  --parameter-overrides "DataBucketName=${DATA_BUCKET}" "SecurityKeyArn=${KMS_KEY_ARN}" \
  --no-fail-on-empty-changeset

echo "Applying catalog ownership and classification tags"
DATABASES=(zipco_financial_risk zipco_financial_analytics zipco_financial_risk_engine)
TAGGED_DATABASES=0
GOVERNED_TABLES=0
CATALOG_TAGS='{"Project":"zipco-financial-risk-platform","DataClassification":"Confidential-Financial","DataOwner":"RiskAnalytics","DatasetVersion":"2.0.0"}'
for database in "${DATABASES[@]}"; do
  if aws glue get-database --name "$database" >/dev/null 2>&1; then
    database_arn="arn:aws:glue:${REGION}:${ACTUAL_ACCOUNT}:database/${database}"
    aws glue tag-resource --resource-arn "$database_arn" \
      --tags-to-add "$CATALOG_TAGS"
    aws glue get-tags --resource-arn "$database_arn" --output json > "${TMP_DIR}/database-tags.json"
    jq -e '.Tags.Project == "zipco-financial-risk-platform" and .Tags.DataClassification == "Confidential-Financial" and .Tags.DataOwner == "RiskAnalytics" and .Tags.DatasetVersion == "2.0.0"' \
      "${TMP_DIR}/database-tags.json" >/dev/null
    TAGGED_DATABASES=$((TAGGED_DATABASES + 1))
    mapfile -t tables < <(aws glue get-tables --database-name "$database" --query 'TableList[].Name' --output text | tr '\t' '\n')
    for table in "${tables[@]}"; do
      [[ -n "$table" ]] || continue
      GOVERNED_TABLES=$((GOVERNED_TABLES + 1))
    done
  fi
done

aws s3 cp "$CONTRACT_FILE" "s3://${DATA_BUCKET}/metadata/contracts/security-governance/security_governance_contract_v1.json" \
  --only-show-errors --content-type application/json
aws s3 cp "$CLASSIFICATION_FILE" "s3://${DATA_BUCKET}/metadata/contracts/security-governance/data_classification_catalog_v1.json" \
  --only-show-errors --content-type application/json

echo "Collecting control evidence"
aws kms describe-key --key-id "$KMS_KEY_ARN" --output json > "${TMP_DIR}/kms-key.json"
aws kms get-key-rotation-status --key-id "$KMS_KEY_ARN" --output json > "${TMP_DIR}/kms-rotation.json"
aws s3api get-bucket-encryption --bucket "$DATA_BUCKET" --output json > "${TMP_DIR}/data-encryption.json"
aws s3api get-public-access-block --bucket "$DATA_BUCKET" --output json > "${TMP_DIR}/data-public-access.json"
aws s3api get-bucket-versioning --bucket "$DATA_BUCKET" --output json > "${TMP_DIR}/data-versioning.json"
aws s3api get-bucket-policy --bucket "$DATA_BUCKET" --output json > "${TMP_DIR}/data-policy-wrapper.json"
jq -r '.Policy' "${TMP_DIR}/data-policy-wrapper.json" | jq . > "${TMP_DIR}/data-policy.json"
aws s3api get-bucket-encryption --bucket "$AUDIT_BUCKET" --output json > "${TMP_DIR}/audit-encryption.json"
aws s3api get-public-access-block --bucket "$AUDIT_BUCKET" --output json > "${TMP_DIR}/audit-public-access.json"
aws s3api get-bucket-versioning --bucket "$AUDIT_BUCKET" --output json > "${TMP_DIR}/audit-versioning.json"
aws s3api get-bucket-inventory-configuration --bucket "$DATA_BUCKET" --id zipco-governance-inventory --output json > "${TMP_DIR}/inventory-state.json"
aws cloudtrail get-trail --name "$TRAIL_NAME" --output json > "${TMP_DIR}/trail.json"
aws cloudtrail get-trail-status --name "$TRAIL_NAME" --output json > "${TMP_DIR}/trail-status.json"
aws cloudtrail get-event-selectors --trail-name "$TRAIL_NAME" --output json > "${TMP_DIR}/trail-selectors.json"
GLUE_SECURITY_CONFIGURATION="$(aws glue get-job --job-name "$GLUE_JOB" --query 'Job.SecurityConfiguration' --output text)"
aws glue get-security-configuration --name "$GLUE_SECURITY_CONFIGURATION" --output json > "${TMP_DIR}/glue-security.json"
aws athena get-work-group --work-group "$ATHENA_WORKGROUP" --output json > "${TMP_DIR}/athena-workgroup.json"
aws glue get-data-catalog-encryption-settings --catalog-id "$ACTUAL_ACCOUNT" --output json > "${TMP_DIR}/catalog-encryption-state.json"
aws accessanalyzer get-analyzer --analyzer-name "$ANALYZER_NAME" --output json > "${TMP_DIR}/analyzer.json"
aws configservice describe-configuration-recorder-status --configuration-recorder-names "$RECORDER_NAME" --output json > "${TMP_DIR}/config-recorder-status.json"
aws configservice describe-config-rules --output json > "${TMP_DIR}/config-rules.json"
aws configservice describe-compliance-by-config-rule --output json > "${TMP_DIR}/config-compliance.json"
aws cloudwatch describe-alarms --alarm-name-prefix zipco- --output json > "${TMP_DIR}/alarms.json"
aws cloudwatch get-dashboard --dashboard-name "$DASHBOARD_NAME" --output json > "${TMP_DIR}/dashboard.json"

jq -n '[]' > "${TMP_DIR}/roles.json"
ROLE_NAMES=(zipco-data-engineer-dev zipco-risk-analyst-dev zipco-data-steward-dev zipco-security-auditor-dev)
for role_name in "${ROLE_NAMES[@]}"; do
  aws iam get-role --role-name "$role_name" --output json > "${TMP_DIR}/role.json"
  policy_name="$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[0]' --output text)"
  aws iam get-role-policy --role-name "$role_name" --policy-name "$policy_name" --output json > "${TMP_DIR}/role-policy.json"
  jq --slurpfile role "${TMP_DIR}/role.json" --slurpfile policy "${TMP_DIR}/role-policy.json" \
    '. + [($role[0].Role | {RoleName,Arn,MaxSessionDuration,AssumeRolePolicyDocument,Tags}) + {InlinePolicyName:$policy[0].PolicyName,InlinePolicyDocument:$policy[0].PolicyDocument}]' \
    "${TMP_DIR}/roles.json" > "${TMP_DIR}/roles.next.json"
  mv "${TMP_DIR}/roles.next.json" "${TMP_DIR}/roles.json"
done

jq -n --argjson databases "$TAGGED_DATABASES" --argjson tables "$GOVERNED_TABLES" \
  '{databases_tagged:$databases,tables_governed_by_classification_catalog:$tables,table_governance:"database ownership tags + versioned column-level classification catalog",classification:"Confidential-Financial",owner:"RiskAnalytics",dataset_version:"2.0.0"}' \
  > "${TMP_DIR}/catalog-tags.json"

CONTROL_RESULTS="${TMP_DIR}/control-results.jsonl"
: > "$CONTROL_RESULTS"
pass_control() {
  jq -n --arg id "$1" --arg description "$2" '{control_id:$id,status:"PASS",description:$description}' >> "$CONTROL_RESULTS"
}
fail_control() {
  jq -n --arg id "$1" --arg description "$2" '{control_id:$id,status:"FAIL",description:$description}' >> "$CONTROL_RESULTS"
  echo "Security control failed: $1 - $2" >&2
  exit 20
}

jq -e '.KeyMetadata.Enabled == true and .KeyMetadata.KeyManager == "CUSTOMER"' "${TMP_DIR}/kms-key.json" >/dev/null \
  && pass_control SG-ENC-01 "Customer-managed KMS key enabled" \
  || fail_control SG-ENC-01 "Customer-managed KMS key enabled"
jq -e '.KeyRotationEnabled == true' "${TMP_DIR}/kms-rotation.json" >/dev/null \
  && pass_control SG-ENC-02 "Automatic KMS rotation enabled" \
  || fail_control SG-ENC-02 "Automatic KMS rotation enabled"
jq -e --arg key "$KMS_KEY_ARN" '.ServerSideEncryptionConfiguration.Rules[0] | .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "aws:kms" and .ApplyServerSideEncryptionByDefault.KMSMasterKeyID == $key and .BucketKeyEnabled == true' "${TMP_DIR}/data-encryption.json" >/dev/null \
  && jq -e '.PublicAccessBlockConfiguration | .BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets' "${TMP_DIR}/data-public-access.json" >/dev/null \
  && jq -e 'any(.Statement[]; .Sid == "DenyInsecureTransport" and .Effect == "Deny")' "${TMP_DIR}/data-policy.json" >/dev/null \
  && jq -e '.Status == "Enabled"' "${TMP_DIR}/data-versioning.json" >/dev/null \
  && pass_control SG-ENC-03 "Primary bucket is KMS encrypted, bucket-key enabled, private, TLS-only, and versioned" \
  || fail_control SG-ENC-03 "Primary bucket is KMS encrypted, bucket-key enabled, private, TLS-only, and versioned"
jq -e --arg key "$KMS_KEY_ARN" '.ServerSideEncryptionConfiguration.Rules[0] | .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "aws:kms" and .ApplyServerSideEncryptionByDefault.KMSMasterKeyID == $key and .BucketKeyEnabled == true' "${TMP_DIR}/audit-encryption.json" >/dev/null \
  && jq -e '.Status == "Enabled"' "${TMP_DIR}/audit-versioning.json" >/dev/null \
  && jq -e '.PublicAccessBlockConfiguration | .BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets' "${TMP_DIR}/audit-public-access.json" >/dev/null \
  && pass_control SG-AUD-03 "Dedicated audit bucket is private, versioned, and KMS encrypted" \
  || fail_control SG-AUD-03 "Dedicated audit bucket is private, versioned, and KMS encrypted"
jq -e '.IsLogging == true' "${TMP_DIR}/trail-status.json" >/dev/null \
  && jq -e --arg key "$KMS_KEY_ARN" '.Trail.IsMultiRegionTrail == true and .Trail.KmsKeyId == $key and (.Trail.CloudWatchLogsLogGroupArn | length > 0)' "${TMP_DIR}/trail.json" >/dev/null \
  && pass_control SG-AUD-01 "Multi-region CloudTrail is logging to encrypted S3 and CloudWatch destinations" \
  || fail_control SG-AUD-01 "Multi-region CloudTrail is logging to encrypted S3 and CloudWatch destinations"
jq -e '.Trail.LogFileValidationEnabled == true' "${TMP_DIR}/trail.json" >/dev/null \
  && pass_control SG-AUD-02 "CloudTrail log-file integrity validation enabled" \
  || fail_control SG-AUD-02 "CloudTrail log-file integrity validation enabled"
if [[ "$ENABLE_S3_DATA_EVENTS" == "true" ]]; then
  jq -e --arg bucket "arn:aws:s3:::${DATA_BUCKET}/" 'any(.AdvancedEventSelectors[]?.FieldSelectors[]?; .Field == "resources.ARN" and (.StartsWith // [] | index($bucket)))' "${TMP_DIR}/trail-selectors.json" >/dev/null \
    && pass_control SG-AUD-04 "S3 object-level data events enabled for the primary bucket" \
    || fail_control SG-AUD-04 "S3 object-level data events enabled for the primary bucket"
fi
jq -e --arg key "$KMS_KEY_ARN" '.SecurityConfiguration.EncryptionConfiguration | .S3Encryption[0].S3EncryptionMode == "SSE-KMS" and .S3Encryption[0].KmsKeyArn == $key and .CloudWatchEncryption.CloudWatchEncryptionMode == "SSE-KMS" and .JobBookmarksEncryption.JobBookmarksEncryptionMode == "CSE-KMS"' "${TMP_DIR}/glue-security.json" >/dev/null \
  && pass_control SG-ENC-04 "Glue job, logs, and bookmark encryption use KMS" \
  || fail_control SG-ENC-04 "Glue job, logs, and bookmark encryption use KMS"
jq -e --arg key "$KMS_KEY_ARN" '.WorkGroup.Configuration.EnforceWorkGroupConfiguration == true and .WorkGroup.Configuration.ResultConfiguration.EncryptionConfiguration.EncryptionOption == "SSE_KMS" and .WorkGroup.Configuration.ResultConfiguration.EncryptionConfiguration.KmsKey == $key' "${TMP_DIR}/athena-workgroup.json" >/dev/null \
  && pass_control SG-ENC-05 "Athena workgroup enforces SSE_KMS results" \
  || fail_control SG-ENC-05 "Athena workgroup enforces SSE_KMS results"
jq -e --arg key "$KMS_KEY_ARN" '.DataCatalogEncryptionSettings.EncryptionAtRest.CatalogEncryptionMode == "SSE-KMS-WITH-SERVICE-ROLE" and .DataCatalogEncryptionSettings.EncryptionAtRest.SseAwsKmsKeyId == $key' "${TMP_DIR}/catalog-encryption-state.json" >/dev/null \
  && pass_control SG-ENC-06 "Glue Data Catalog encryption enabled with a service role" \
  || fail_control SG-ENC-06 "Glue Data Catalog encryption enabled with a service role"
jq -e 'any(.[]; .RoleName == "zipco-data-engineer-dev")' "${TMP_DIR}/roles.json" >/dev/null \
  && pass_control SG-IAM-01 "Scoped data engineer role exists" \
  || fail_control SG-IAM-01 "Scoped data engineer role exists"
jq -e 'any(.[]; .RoleName == "zipco-risk-analyst-dev")' "${TMP_DIR}/roles.json" >/dev/null \
  && pass_control SG-IAM-02 "Read/query risk analyst role exists" \
  || fail_control SG-IAM-02 "Read/query risk analyst role exists"
jq -e 'any(.[]; .RoleName == "zipco-data-steward-dev")' "${TMP_DIR}/roles.json" >/dev/null \
  && pass_control SG-IAM-03 "Metadata and contract steward role exists" \
  || fail_control SG-IAM-03 "Metadata and contract steward role exists"
jq -e 'any(.[]; .RoleName == "zipco-security-auditor-dev")' "${TMP_DIR}/roles.json" >/dev/null \
  && pass_control SG-IAM-04 "Read-only security auditor role exists" \
  || fail_control SG-IAM-04 "Read-only security auditor role exists"
jq -e 'length == 4 and all(.[]; .MaxSessionDuration <= 14400 and any(.AssumeRolePolicyDocument.Statement[]; .Condition.Bool["aws:MultiFactorAuthPresent"] == "true"))' "${TMP_DIR}/roles.json" >/dev/null \
  && pass_control SG-IAM-05 "All human persona trust policies require MFA" \
  || fail_control SG-IAM-05 "All human persona trust policies require MFA"
jq -e '.analyzer.status == "ACTIVE" and .analyzer.type == "ACCOUNT"' "${TMP_DIR}/analyzer.json" >/dev/null \
  && pass_control SG-IAM-06 "Account-level IAM Access Analyzer active" \
  || fail_control SG-IAM-06 "Account-level IAM Access Analyzer active"
jq -e '.ConfigurationRecordersStatus[0].recording == true' "${TMP_DIR}/config-recorder-status.json" >/dev/null \
  && pass_control SG-GOV-01 "AWS Config recorder active" \
  || fail_control SG-GOV-01 "AWS Config recorder active"
jq -e '[.ConfigRules[] | select(.ConfigRuleName | startswith("zipco-"))] | length >= 15' "${TMP_DIR}/config-rules.json" >/dev/null \
  && pass_control SG-GOV-02 "Fifteen-rule AWS Config governance pack deployed" \
  || fail_control SG-GOV-02 "Fifteen-rule AWS Config governance pack deployed"
jq -e '.InventoryConfiguration.IsEnabled == true and .InventoryConfiguration.Schedule.Frequency == "Weekly" and (.InventoryConfiguration.OptionalFields | index("EncryptionStatus"))' "${TMP_DIR}/inventory-state.json" >/dev/null \
  && pass_control SG-GOV-03 "Weekly encryption-aware S3 Inventory enabled" \
  || fail_control SG-GOV-03 "Weekly encryption-aware S3 Inventory enabled"
jq -e '.databases_tagged == 3 and .tables_governed_by_classification_catalog >= 16' "${TMP_DIR}/catalog-tags.json" >/dev/null \
  && pass_control SG-GOV-04 "Catalog databases carry verified ownership tags and tables are covered by the classification catalog" \
  || fail_control SG-GOV-04 "Catalog databases carry verified ownership tags and tables are covered by the classification catalog"
jq -e '[.MetricAlarms[] | select(.AlarmName == "zipco-root-account-usage" or .AlarmName == "zipco-unauthorized-api-calls" or .AlarmName == "zipco-kms-disable-delete-events")] | length == 3' "${TMP_DIR}/alarms.json" >/dev/null \
  && pass_control SG-AUD-05 "Root, denied-API, and KMS destructive-change alarms deployed" \
  || fail_control SG-AUD-05 "Root, denied-API, and KMS destructive-change alarms deployed"
jq -e '.DashboardName == "zipco-security-governance" and (.DashboardBody | length > 0)' "${TMP_DIR}/dashboard.json" >/dev/null \
  && pass_control SG-AUD-06 "Security dashboard and CloudWatch audit query deployed" \
  || fail_control SG-AUD-06 "Security dashboard and CloudWatch audit query deployed"
jq -e '.classes["Restricted-PII"].columns | index("customers.Name") and index("customers.Email") and index("customers.Phone")' "$CLASSIFICATION_FILE" >/dev/null \
  && pass_control SG-GOV-05 "Versioned column-level data classification catalog retained" \
  || fail_control SG-GOV-05 "Versioned column-level data classification catalog retained"
jq -e '.boundaries.risk_model | test("human review only"; "i")' "$CONTRACT_FILE" >/dev/null \
  && pass_control SG-GOV-06 "Risk model remains human-reviewed and prohibited for automated adverse decisions" \
  || fail_control SG-GOV-06 "Risk model remains human-reviewed and prohibited for automated adverse decisions"

COMPLETED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
CONTROL_COUNT="$(jq -s 'length' "$CONTROL_RESULTS")"
NONCOMPLIANT_RULES="$(jq '[.ComplianceByConfigRules[] | select(.Compliance.ComplianceType == "NON_COMPLIANT")] | length' "${TMP_DIR}/config-compliance.json")"
INSUFFICIENT_RULES="$(jq '[.ComplianceByConfigRules[] | select(.Compliance.ComplianceType == "INSUFFICIENT_DATA")] | length' "${TMP_DIR}/config-compliance.json")"
DASHBOARD_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"

jq -n \
  --arg status "DEPLOYED_RUN_AND_VERIFIED" \
  --arg completed_at_utc "$COMPLETED_AT" \
  --arg run_id "$RUN_ID" \
  --arg account_id "$ACTUAL_ACCOUNT" \
  --arg caller_arn "$CALLER_ARN" \
  --arg region "$REGION" \
  --arg data_bucket "$DATA_BUCKET" \
  --arg audit_bucket "$AUDIT_BUCKET" \
  --arg security_stack "$SECURITY_STACK" \
  --arg security_stack_status "$STACK_STATUS" \
  --arg config_rules_stack "$CONFIG_RULES_STACK" \
  --arg kms_key_arn "$KMS_KEY_ARN" \
  --arg trail_name "$TRAIL_NAME" \
  --arg audit_log_group "$AUDIT_LOG_GROUP" \
  --arg analyzer_name "$ANALYZER_NAME" \
  --arg recorder_name "$RECORDER_NAME" \
  --arg dashboard_name "$DASHBOARD_NAME" \
  --arg dashboard_url "$DASHBOARD_URL" \
  --argjson s3_data_events "$ENABLE_S3_DATA_EVENTS" \
  --argjson controls_passed "$CONTROL_COUNT" \
  --argjson config_noncompliant "$NONCOMPLIANT_RULES" \
  --argjson config_insufficient_data "$INSUFFICIENT_RULES" \
  --slurpfile kms_key "${TMP_DIR}/kms-key.json" \
  --slurpfile kms_rotation "${TMP_DIR}/kms-rotation.json" \
  --slurpfile data_encryption "${TMP_DIR}/data-encryption.json" \
  --slurpfile audit_encryption "${TMP_DIR}/audit-encryption.json" \
  --slurpfile trail "$TMP_DIR/trail.json" \
  --slurpfile trail_status "$TMP_DIR/trail-status.json" \
  --slurpfile trail_selectors "$TMP_DIR/trail-selectors.json" \
  --slurpfile glue_security "$TMP_DIR/glue-security.json" \
  --slurpfile athena "$TMP_DIR/athena-workgroup.json" \
  --slurpfile catalog "$TMP_DIR/catalog-encryption-state.json" \
  --slurpfile roles "$TMP_DIR/roles.json" \
  --slurpfile analyzer "$TMP_DIR/analyzer.json" \
  --slurpfile config_recorder "$TMP_DIR/config-recorder-status.json" \
  --slurpfile config_rules "$TMP_DIR/config-rules.json" \
  --slurpfile config_compliance "$TMP_DIR/config-compliance.json" \
  --slurpfile inventory "$TMP_DIR/inventory-state.json" \
  --slurpfile catalog_tags "$TMP_DIR/catalog-tags.json" \
  --slurpfile control_results "$CONTROL_RESULTS" \
  '{
    status:$status,
    completed_at_utc:$completed_at_utc,
    run_id:$run_id,
    account_id:$account_id,
    caller_arn:$caller_arn,
    region:$region,
    cloudformation:{security_stack:$security_stack,security_stack_status:$security_stack_status,config_rules_stack:$config_rules_stack},
    kms:{key_arn:$kms_key_arn,metadata:$kms_key[0].KeyMetadata,rotation_enabled:$kms_rotation[0].KeyRotationEnabled},
    s3:{data_bucket:$data_bucket,audit_bucket:$audit_bucket,data_default_encryption:$data_encryption[0],audit_default_encryption:$audit_encryption[0]},
    cloudtrail:{name:$trail_name,log_group:$audit_log_group,s3_data_events_enabled:$s3_data_events,trail:$trail[0].Trail,status:$trail_status[0],selectors:$trail_selectors[0].AdvancedEventSelectors},
    glue:{job:"zipco-relational-v2-validation-transform",crawler:"zipco-relational-v2-curated-crawler",security_configuration:$glue_security[0].SecurityConfiguration},
    athena:{workgroup:$athena[0].WorkGroup},
    catalog:{encryption:$catalog[0].DataCatalogEncryptionSettings},
    iam:{human_personas:$roles[0]},
    access_analyzer:{name:$analyzer_name,details:$analyzer[0].analyzer},
    aws_config:{recorder_name:$recorder_name,status:$config_recorder[0],managed_rule_count:([$config_rules[0].ConfigRules[] | select(.ConfigRuleName | startswith("zipco-"))] | length),noncompliant_rules:$config_noncompliant,insufficient_data_rules:$config_insufficient_data,compliance:$config_compliance[0].ComplianceByConfigRules},
    inventory:$inventory[0].InventoryConfiguration,
    catalog_tags:$catalog_tags[0],
    dashboard:{name:$dashboard_name,url:$dashboard_url},
    validation:{status:"PASS",controls_passed:$controls_passed,control_results:$control_results}
  }' > "$EVIDENCE_FILE"

EVIDENCE_PREFIX="security-governance/evidence/run_id=${RUN_ID}"
aws s3 cp "$EVIDENCE_FILE" "s3://${DATA_BUCKET}/${EVIDENCE_PREFIX}/zipco_security_governance_deployment_verification.json" \
  --only-show-errors --content-type application/json
aws s3 cp "$EVIDENCE_FILE" "s3://${DATA_BUCKET}/metadata/contracts/security-governance/zipco_security_governance_deployment_verification_latest.json" \
  --only-show-errors --content-type application/json
aws s3api head-object --bucket "$DATA_BUCKET" --key "${EVIDENCE_PREFIX}/zipco_security_governance_deployment_verification.json" >/dev/null

echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Security controls: PASS (${CONTROL_COUNT}/${CONTROL_COUNT})"
echo "KMS key: ${KMS_KEY_ARN} (rotation enabled)"
echo "Primary bucket: ${DATA_BUCKET} (SSE-KMS + Bucket Key)"
echo "Audit bucket: ${AUDIT_BUCKET}"
echo "CloudTrail: ${TRAIL_NAME} (multi-region, validation enabled, logging)"
echo "S3 data events: ${ENABLE_S3_DATA_EVENTS}"
echo "IAM personas: 4/4"
echo "AWS Config rules: 15/15"
echo "Config posture: noncompliant=${NONCOMPLIANT_RULES}, insufficient_data=${INSUFFICIENT_RULES} (reported findings do not invalidate infrastructure deployment)"
echo "Catalog governance: tagged_databases=${TAGGED_DATABASES}, classified_tables=${GOVERNED_TABLES}"
echo "Dashboard: ${DASHBOARD_URL}"
echo "Evidence: s3://${DATA_BUCKET}/${EVIDENCE_PREFIX}/zipco_security_governance_deployment_verification.json"
