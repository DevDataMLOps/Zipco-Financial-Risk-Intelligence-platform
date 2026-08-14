#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ACCOUNT="825999268272"
REGION="us-east-2"
BUCKET="zipco-financial-platform-${EXPECTED_ACCOUNT}-${REGION}"
STACK_NAME="zipco-glue-relational-v2"
JOB_NAME="zipco-relational-v2-validation-transform"
CRAWLER_NAME="zipco-relational-v2-curated-crawler"
DATABASE_NAME="zipco_financial_risk"
MANIFEST_KEY="metadata/contracts/relational_v2/generation_manifest.json"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ETL_SCRIPT="${SCRIPT_DIR}/zipco_relational_v2_etl.py"
CFN_TEMPLATE="${SCRIPT_DIR}/zipco_glue_infrastructure.json"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

for required in "$ETL_SCRIPT" "$CFN_TEMPLATE"; do
  [[ -f "$required" ]] || { echo "Missing required file: $required" >&2; exit 2; }
done

ACTUAL_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
if [[ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  echo "Refusing deployment: expected account $EXPECTED_ACCOUNT but authenticated to $ACTUAL_ACCOUNT." >&2
  exit 3
fi

aws s3api head-bucket --bucket "$BUCKET"
MANIFEST_FILE="$(mktemp)"
OBJECT_VERIFICATION="$(mktemp)"
cleanup() {
  rm -f "$MANIFEST_FILE" "$OBJECT_VERIFICATION"
}
trap cleanup EXIT

aws s3 cp "s3://${BUCKET}/${MANIFEST_KEY}" "$MANIFEST_FILE" --only-show-errors
for table in customers accounts transactions transaction_categories categorized_transactions market_data; do
  key="validated/relational_v2/${table}/${table}.csv"
  expected_hash="$(jq -r --arg table "$table" '.tables[$table].sha256' "$MANIFEST_FILE")"
  expected_bytes="$(jq -r --arg table "$table" '.tables[$table].bytes' "$MANIFEST_FILE")"
  expected_rows="$(jq -r --arg table "$table" '.tables[$table].rows' "$MANIFEST_FILE")"
  source_metadata="$(aws s3api head-object --bucket "$BUCKET" --key "$key" --output json)"
  remote_hash="$(jq -r '.Metadata.sha256' <<< "$source_metadata")"
  remote_version="$(jq -r '.Metadata["dataset-version"]' <<< "$source_metadata")"
  remote_rows="$(jq -r '.Metadata.rows' <<< "$source_metadata")"
  remote_bytes="$(jq -r '.ContentLength' <<< "$source_metadata")"
  remote_encryption="$(jq -r '.ServerSideEncryption' <<< "$source_metadata")"
  if [[ "$remote_hash" != "$expected_hash" || "$remote_version" != "2.0.0" || "$remote_rows" != "$expected_rows" || "$remote_bytes" != "$expected_bytes" || "$remote_encryption" != "AES256" ]]; then
    echo "Source contract verification failed for $table" >&2
    exit 4
  fi
done

echo "Uploading Glue ETL script"
aws s3 cp "$ETL_SCRIPT" "s3://${BUCKET}/glue/scripts/zipco_relational_v2_etl.py" \
  --only-show-errors \
  --sse AES256 \
  --checksum-algorithm SHA256 \
  --content-type text/x-python \
  --metadata "sha256=$(sha256sum "$ETL_SCRIPT" | awk '{print $1}'),dataset-version=2.0.0"

echo "Validating CloudFormation template"
aws cloudformation validate-template --template-body "file://${CFN_TEMPLATE}" >/dev/null

echo "Deploying Glue infrastructure"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$CFN_TEMPLATE" \
  --parameter-overrides "BucketName=${BUCKET}" "Environment=dev" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
case "$STACK_STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE) ;;
  *) echo "Unexpected stack status: $STACK_STATUS" >&2; exit 10 ;;
esac

echo "Starting Glue validation and transformation job"
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-cloudshell"
JOB_RUN_ID="$(aws glue start-job-run \
  --job-name "$JOB_NAME" \
  --arguments "{\"--PIPELINE_RUN_ID\":\"${RUN_ID}\"}" \
  --query JobRunId \
  --output text)"
echo "Job run ID: $JOB_RUN_ID"

while true; do
  JOB_STATE="$(aws glue get-job-run --job-name "$JOB_NAME" --run-id "$JOB_RUN_ID" --query 'JobRun.JobRunState' --output text)"
  echo "Glue job state: $JOB_STATE"
  case "$JOB_STATE" in
    SUCCEEDED) break ;;
    FAILED|STOPPED|TIMEOUT|ERROR|EXPIRED)
      aws glue get-job-run --job-name "$JOB_NAME" --run-id "$JOB_RUN_ID" --query 'JobRun.[ErrorMessage,StateDetail]' --output json
      exit 11
      ;;
  esac
  sleep 20
done

QUALITY_KEY="quality/relational_v2/run_id=${RUN_ID}/summary.json"
aws s3api head-object --bucket "$BUCKET" --key "$QUALITY_KEY" >/dev/null
aws s3 cp "s3://${BUCKET}/${QUALITY_KEY}" "${SCRIPT_DIR}/glue_quality_summary.json" --only-show-errors
QUALITY_STATUS="$(jq -r '.overall_status' "${SCRIPT_DIR}/glue_quality_summary.json")"
PUBLICATION_ALLOWED="$(jq -r '.publication_allowed' "${SCRIPT_DIR}/glue_quality_summary.json")"
TOTAL_REJECTED="$(jq -r '.total_records_rejected' "${SCRIPT_DIR}/glue_quality_summary.json")"
if [[ "$QUALITY_STATUS" != "PASS" || "$PUBLICATION_ALLOWED" != "true" || "$TOTAL_REJECTED" != "0" ]]; then
  echo "Unexpected Glue quality result: status=${QUALITY_STATUS}, publication=${PUBLICATION_ALLOWED}, rejected=${TOTAL_REJECTED}" >&2
  exit 12
fi

echo "Starting curated Parquet crawler"
PREVIOUS_CRAWL_START="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.LastCrawl.StartTime' --output text)"
aws glue start-crawler --name "$CRAWLER_NAME"
while true; do
  CRAWLER_STATE="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.State' --output text)"
  CURRENT_CRAWL_START="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.LastCrawl.StartTime' --output text)"
  echo "Crawler state: $CRAWLER_STATE"
  if [[ "$CRAWLER_STATE" == "READY" && "$CURRENT_CRAWL_START" != "None" && "$CURRENT_CRAWL_START" != "$PREVIOUS_CRAWL_START" ]]; then
    break
  fi
  sleep 15
done

LAST_CRAWL_STATUS="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.LastCrawl.Status' --output text)"
if [[ "$LAST_CRAWL_STATUS" != "SUCCEEDED" ]]; then
  aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.LastCrawl' --output json
  exit 13
fi

TABLE_NAMES_JSON="$(aws glue get-tables --database-name "$DATABASE_NAME" --query 'sort(TableList[].Name)' --output json)"
TABLE_COUNT="$(jq 'length' <<< "$TABLE_NAMES_JSON")"
EXPECTED_TABLES_JSON='["zipco_v2_accounts","zipco_v2_categorized_transactions","zipco_v2_customers","zipco_v2_market_data","zipco_v2_transaction_categories","zipco_v2_transactions"]'
if [[ "$TABLE_COUNT" != "6" ]] || ! jq -e --argjson expected "$EXPECTED_TABLES_JSON" 'sort == ($expected | sort)' <<< "$TABLE_NAMES_JSON" >/dev/null; then
  echo "Glue catalog table mismatch. Expected $EXPECTED_TABLES_JSON but received $TABLE_NAMES_JSON" >&2
  exit 14
fi

for table in customers accounts transactions transaction_categories categorized_transactions market_data; do
  object_count="$(aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "curated/relational_v2/${table}/" \
    --query 'length(Contents[?ends_with(Key, `.parquet`)])' \
    --output text)"
  total_bytes="$(aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "curated/relational_v2/${table}/" \
    --query 'sum(Contents[?ends_with(Key, `.parquet`)].Size)' \
    --output text)"
  if [[ "$object_count" == "0" || "$object_count" == "None" ]]; then
    echo "No Parquet objects found for $table" >&2
    exit 15
  fi
  jq -n \
    --arg table "$table" \
    --argjson parquet_objects "$object_count" \
    --argjson parquet_bytes "${total_bytes:-0}" \
    '{table:$table,parquet_objects:$parquet_objects,parquet_bytes:$parquet_bytes}' >> "$OBJECT_VERIFICATION"
done

JOB_RUN_JSON="$(aws glue get-job-run --job-name "$JOB_NAME" --run-id "$JOB_RUN_ID" --output json)"
COMPLETED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
jq -s \
  --arg status "DEPLOYED_RUN_AND_VERIFIED" \
  --arg completed_at_utc "$COMPLETED_AT" \
  --arg account_id "$ACTUAL_ACCOUNT" \
  --arg caller_arn "$CALLER_ARN" \
  --arg region "$REGION" \
  --arg bucket "$BUCKET" \
  --arg stack_name "$STACK_NAME" \
  --arg stack_status "$STACK_STATUS" \
  --arg job_name "$JOB_NAME" \
  --arg job_run_id "$JOB_RUN_ID" \
  --arg pipeline_run_id "$RUN_ID" \
  --arg crawler_name "$CRAWLER_NAME" \
  --arg crawler_status "$LAST_CRAWL_STATUS" \
  --arg database_name "$DATABASE_NAME" \
  --argjson catalog_tables "$TABLE_NAMES_JSON" \
  --argjson glue_job_run "$JOB_RUN_JSON" \
  --slurpfile quality "${SCRIPT_DIR}/glue_quality_summary.json" \
  '{
    status:$status,
    completed_at_utc:$completed_at_utc,
    account_id:$account_id,
    caller_arn:$caller_arn,
    region:$region,
    bucket:$bucket,
    cloudformation:{stack_name:$stack_name,status:$stack_status},
    glue_job:{name:$job_name,job_run_id:$job_run_id,pipeline_run_id:$pipeline_run_id,details:$glue_job_run.JobRun},
    data_quality:$quality[0],
    crawler:{name:$crawler_name,status:$crawler_status},
    catalog:{database:$database_name,tables:$catalog_tables},
    curated_objects:.
  }' "$OBJECT_VERIFICATION" > "${SCRIPT_DIR}/zipco_glue_deployment_verification.json"

aws s3 cp "${SCRIPT_DIR}/zipco_glue_deployment_verification.json" \
  "s3://${BUCKET}/metadata/contracts/relational_v2/zipco_glue_deployment_verification.json" \
  --only-show-errors \
  --sse AES256 \
  --checksum-algorithm SHA256 \
  --content-type application/json

echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Glue job: $JOB_NAME"
echo "Job run: $JOB_RUN_ID"
echo "Quality status: $QUALITY_STATUS"
echo "Rejected records: $TOTAL_REJECTED"
echo "Crawler status: $LAST_CRAWL_STATUS"
echo "Catalog database: $DATABASE_NAME"
echo "Catalog tables: $TABLE_NAMES_JSON"
echo "Curated prefix: s3://${BUCKET}/curated/relational_v2/"
