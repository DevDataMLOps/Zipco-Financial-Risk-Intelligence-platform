#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ACCOUNT="825999268272"
REGION="us-east-2"
BUCKET="zipco-financial-platform-${EXPECTED_ACCOUNT}-${REGION}"
STACK_NAME="zipco-athena-analytics"
WORKGROUP="zipco-risk-analytics"
SOURCE_DATABASE="zipco_financial_risk"
ANALYTICS_DATABASE="zipco_financial_analytics"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFN_TEMPLATE="${SCRIPT_DIR}/zipco_athena_infrastructure.json"
VIEWS_DIR="${SCRIPT_DIR}/views"
VALIDATION_DIR="${SCRIPT_DIR}/validation"
ANALYTICS_DIR="${SCRIPT_DIR}/analytics"
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-cloudshell"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

QUERY_RUNS_FILE="$(mktemp)"
VALIDATION_RESULTS_FILE="$(mktemp)"
ANALYTICS_RESULTS_FILE="$(mktemp)"
WORKGROUP_FILE="$(mktemp)"
VIEWS_FILE="$(mktemp)"
NAMED_QUERIES_FILE="$(mktemp)"
EVIDENCE_FILE="${SCRIPT_DIR}/zipco_athena_deployment_verification.json"

cleanup() {
  rm -f "$QUERY_RUNS_FILE" "$VALIDATION_RESULTS_FILE" "$ANALYTICS_RESULTS_FILE" \
    "$WORKGROUP_FILE" "$VIEWS_FILE" "$NAMED_QUERIES_FILE"
}
trap cleanup EXIT

for required in "$CFN_TEMPLATE" "$VIEWS_DIR" "$VALIDATION_DIR" "$ANALYTICS_DIR"; do
  [[ -e "$required" ]] || { echo "Missing required artifact: $required" >&2; exit 2; }
done
for command_name in aws jq sha256sum; do
  command -v "$command_name" >/dev/null || { echo "Required command unavailable: $command_name" >&2; exit 3; }
done

ACTUAL_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
if [[ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  echo "Refusing deployment: expected account $EXPECTED_ACCOUNT but authenticated to $ACTUAL_ACCOUNT." >&2
  exit 4
fi

aws s3api head-bucket --bucket "$BUCKET"
SOURCE_TABLES_JSON="$(aws glue get-tables --database-name "$SOURCE_DATABASE" --query 'sort(TableList[?TableType!=`VIRTUAL_VIEW`].Name)' --output json)"
EXPECTED_SOURCE_TABLES='["zipco_v2_accounts","zipco_v2_categorized_transactions","zipco_v2_customers","zipco_v2_market_data","zipco_v2_transaction_categories","zipco_v2_transactions"]'
if ! jq -e --argjson expected "$EXPECTED_SOURCE_TABLES" 'sort == ($expected | sort)' <<< "$SOURCE_TABLES_JSON" >/dev/null; then
  echo "Source catalog contract failed. Expected $EXPECTED_SOURCE_TABLES but received $SOURCE_TABLES_JSON" >&2
  exit 5
fi

echo "Uploading governed Athena SQL assets"
aws s3 sync "$VIEWS_DIR" "s3://${BUCKET}/athena/sql/v1/views/" --only-show-errors --sse AES256 --exclude "*" --include "*.sql"
aws s3 sync "$VALIDATION_DIR" "s3://${BUCKET}/athena/sql/v1/validation/" --only-show-errors --sse AES256 --exclude "*" --include "*.sql"
aws s3 sync "$ANALYTICS_DIR" "s3://${BUCKET}/athena/sql/v1/analytics/" --only-show-errors --sse AES256 --exclude "*" --include "*.sql"

echo "Deploying Athena workgroup, analytics database, and saved queries"
aws cloudformation validate-template --template-body "file://${CFN_TEMPLATE}" >/dev/null
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$CFN_TEMPLATE" \
  --parameter-overrides "BucketName=${BUCKET}" "Environment=dev" \
  --no-fail-on-empty-changeset

STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
case "$STACK_STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE) ;;
  *) echo "Unexpected stack status: $STACK_STATUS" >&2; exit 6 ;;
esac

aws athena get-work-group --work-group "$WORKGROUP" --output json > "$WORKGROUP_FILE"
if ! jq -e --arg bucket "$BUCKET" '
  .WorkGroup.State == "ENABLED"
  and .WorkGroup.Configuration.EnforceWorkGroupConfiguration == true
  and .WorkGroup.Configuration.PublishCloudWatchMetricsEnabled == true
  and .WorkGroup.Configuration.BytesScannedCutoffPerQuery == 524288000
  and .WorkGroup.Configuration.ResultConfiguration.OutputLocation == ("s3://" + $bucket + "/athena/results/")
  and .WorkGroup.Configuration.ResultConfiguration.EncryptionConfiguration.EncryptionOption == "SSE_S3"
' "$WORKGROUP_FILE" >/dev/null; then
  echo "Athena workgroup governance verification failed." >&2
  exit 7
fi

run_query() {
  local sql_file="$1"
  local database="$2"
  local category="$3"
  local label="$4"
  local sql query_id state execution reason

  sql="$(<"$sql_file")"
  query_id="$(aws athena start-query-execution \
    --query-string "$sql" \
    --query-execution-context "Database=${database},Catalog=AwsDataCatalog" \
    --work-group "$WORKGROUP" \
    --query QueryExecutionId \
    --output text)"

  while true; do
    execution="$(aws athena get-query-execution --query-execution-id "$query_id" --output json)"
    state="$(jq -r '.QueryExecution.Status.State' <<< "$execution")"
    case "$state" in
      SUCCEEDED) break ;;
      FAILED|CANCELLED)
        reason="$(jq -r '.QueryExecution.Status.StateChangeReason // "No failure reason supplied"' <<< "$execution")"
        echo "Athena query failed [${label}] ${query_id}: ${reason}" >&2
        return 20
        ;;
    esac
    sleep 3
  done

  jq -n \
    --arg category "$category" \
    --arg label "$label" \
    --arg sql_file "$(basename "$sql_file")" \
    --arg sql_sha256 "$(sha256sum "$sql_file" | awk '{print $1}')" \
    --arg query_execution_id "$query_id" \
    --arg state "$state" \
    --arg database "$database" \
    --arg output_location "$(jq -r '.QueryExecution.ResultConfiguration.OutputLocation // ""' <<< "$execution")" \
    --argjson data_scanned_bytes "$(jq -r '.QueryExecution.Statistics.DataScannedInBytes // 0' <<< "$execution")" \
    --argjson engine_execution_ms "$(jq -r '.QueryExecution.Statistics.EngineExecutionTimeInMillis // 0' <<< "$execution")" \
    '{category:$category,label:$label,sql_file:$sql_file,sql_sha256:$sql_sha256,query_execution_id:$query_execution_id,state:$state,database:$database,output_location:$output_location,data_scanned_bytes:$data_scanned_bytes,engine_execution_ms:$engine_execution_ms}' \
    >> "$QUERY_RUNS_FILE"

  echo "${category}: ${label} -> SUCCEEDED" >&2
  printf '%s' "$query_id"
}

echo "Creating reusable analytics views"
for sql_file in "$VIEWS_DIR"/*.sql; do
  run_query "$sql_file" "$ANALYTICS_DATABASE" "VIEW_DDL" "$(basename "$sql_file" .sql)" >/dev/null
done

aws glue get-tables --database-name "$ANALYTICS_DATABASE" \
  --query 'sort_by(TableList[?TableType==`VIRTUAL_VIEW`],&Name)[].{Name:Name,TableType:TableType}' \
  --output json > "$VIEWS_FILE"
EXPECTED_VIEWS='["v_account_risk_signals","v_customer_portfolio","v_monthly_risk_metrics","v_transaction_enriched"]'
ACTUAL_VIEWS="$(jq '[.[].Name] | sort' "$VIEWS_FILE")"
if ! jq -e --argjson expected "$EXPECTED_VIEWS" 'sort == ($expected | sort)' <<< "$ACTUAL_VIEWS" >/dev/null; then
  echo "Analytics view contract failed. Expected $EXPECTED_VIEWS but received $ACTUAL_VIEWS" >&2
  exit 8
fi

echo "Running eight Athena validation rules"
for sql_file in "$VALIDATION_DIR"/*.sql; do
  label="$(basename "$sql_file" .sql)"
  query_id="$(run_query "$sql_file" "$ANALYTICS_DATABASE" "VALIDATION" "$label")"
  result="$(aws athena get-query-results --query-execution-id "$query_id" --max-items 10 --output json)"
  rule_id="$(jq -r '.ResultSet.Rows[1].Data[0].VarCharValue // "MISSING"' <<< "$result")"
  status="$(jq -r '.ResultSet.Rows[1].Data[1].VarCharValue // "MISSING"' <<< "$result")"
  actual="$(jq -r '.ResultSet.Rows[1].Data[2].VarCharValue // ""' <<< "$result")"
  expected="$(jq -r '.ResultSet.Rows[1].Data[3].VarCharValue // ""' <<< "$result")"
  details="$(jq -r '.ResultSet.Rows[1].Data[4].VarCharValue // ""' <<< "$result")"
  jq -n \
    --arg rule_id "$rule_id" --arg status "$status" --arg actual "$actual" \
    --arg expected "$expected" --arg details "$details" --arg query_execution_id "$query_id" \
    '{rule_id:$rule_id,status:$status,actual:$actual,expected:$expected,details:$details,query_execution_id:$query_execution_id}' \
    >> "$VALIDATION_RESULTS_FILE"
  if [[ "$status" != "PASS" ]]; then
    echo "Athena validation failed: ${rule_id}; actual=${actual}; expected=${expected}; ${details}" >&2
    exit 9
  fi
done

echo "Executing four portfolio analytics queries"
for sql_file in "$ANALYTICS_DIR"/*.sql; do
  label="$(basename "$sql_file" .sql)"
  query_id="$(run_query "$sql_file" "$ANALYTICS_DATABASE" "ANALYTICS" "$label")"
  result="$(aws athena get-query-results --query-execution-id "$query_id" --max-items 1000 --output json)"
  data_rows="$(jq '([.ResultSet.Rows[]?] | length) - 1' <<< "$result")"
  if (( data_rows < 1 )); then
    echo "Analytics query returned no data rows: $label" >&2
    exit 10
  fi
  jq -n \
    --arg query "$label" --arg query_execution_id "$query_id" --argjson returned_rows "$data_rows" \
    '{query:$query,query_execution_id:$query_execution_id,returned_rows:$returned_rows,status:"PASS"}' \
    >> "$ANALYTICS_RESULTS_FILE"
done

aws athena list-named-queries --work-group "$WORKGROUP" --output json > "$NAMED_QUERIES_FILE"
NAMED_QUERY_COUNT="$(jq '.NamedQueryIds | length' "$NAMED_QUERIES_FILE")"
if [[ "$NAMED_QUERY_COUNT" != "4" ]]; then
  echo "Expected four saved queries but found $NAMED_QUERY_COUNT." >&2
  exit 11
fi

COMPLETED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
jq -n \
  --arg status "DEPLOYED_RUN_AND_VERIFIED" \
  --arg completed_at_utc "$COMPLETED_AT" \
  --arg pipeline_run_id "$RUN_ID" \
  --arg account_id "$ACTUAL_ACCOUNT" \
  --arg caller_arn "$CALLER_ARN" \
  --arg region "$REGION" \
  --arg bucket "$BUCKET" \
  --arg stack_name "$STACK_NAME" \
  --arg stack_status "$STACK_STATUS" \
  --arg workgroup "$WORKGROUP" \
  --arg source_database "$SOURCE_DATABASE" \
  --arg analytics_database "$ANALYTICS_DATABASE" \
  --slurpfile workgroup_configuration "$WORKGROUP_FILE" \
  --slurpfile views "$VIEWS_FILE" \
  --slurpfile query_runs "$QUERY_RUNS_FILE" \
  --slurpfile validation_results "$VALIDATION_RESULTS_FILE" \
  --slurpfile analytics_results "$ANALYTICS_RESULTS_FILE" \
  --slurpfile named_queries "$NAMED_QUERIES_FILE" \
  '{
    status:$status,
    completed_at_utc:$completed_at_utc,
    pipeline_run_id:$pipeline_run_id,
    account_id:$account_id,
    caller_arn:$caller_arn,
    region:$region,
    bucket:$bucket,
    cloudformation:{stack_name:$stack_name,status:$stack_status},
    athena:{workgroup:$workgroup,source_database:$source_database,analytics_database:$analytics_database,configuration:$workgroup_configuration[0].WorkGroup},
    views:$views[0],
    saved_query_ids:$named_queries[0].NamedQueryIds,
    validations:{status:"PASS",rules_passed:($validation_results|length),rules:$validation_results},
    analytics:{status:"PASS",queries_passed:($analytics_results|length),queries:$analytics_results},
    query_executions:$query_runs,
    total_data_scanned_bytes:([$query_runs[].data_scanned_bytes] | add)
  }' > "$EVIDENCE_FILE"

EVIDENCE_PREFIX="athena/evidence/run_id=${RUN_ID}"
aws s3 cp "$EVIDENCE_FILE" "s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_athena_deployment_verification.json" --only-show-errors --sse AES256 --content-type application/json
aws s3 cp "$EVIDENCE_FILE" "s3://${BUCKET}/metadata/contracts/relational_v2/zipco_athena_deployment_verification.json" --only-show-errors --sse AES256 --content-type application/json

VALIDATION_COUNT="$(jq '.validations.rules_passed' "$EVIDENCE_FILE")"
ANALYTICS_COUNT="$(jq '.analytics.queries_passed' "$EVIDENCE_FILE")"
VIEW_COUNT="$(jq '.views | length' "$EVIDENCE_FILE")"
TOTAL_SCANNED="$(jq '.total_data_scanned_bytes' "$EVIDENCE_FILE")"

echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Athena workgroup: $WORKGROUP"
echo "Source database: $SOURCE_DATABASE"
echo "Analytics database: $ANALYTICS_DATABASE"
echo "Views: $VIEW_COUNT/4"
echo "Validation status: PASS (${VALIDATION_COUNT}/8)"
echo "Analytics queries: PASS (${ANALYTICS_COUNT}/4)"
echo "Saved queries: ${NAMED_QUERY_COUNT}/4"
echo "Total data scanned (bytes): $TOTAL_SCANNED"
echo "Evidence: s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_athena_deployment_verification.json"
