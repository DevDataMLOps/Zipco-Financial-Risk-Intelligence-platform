#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ACCOUNT="825999268272"
REGION="us-east-2"
BUCKET="zipco-financial-platform-${EXPECTED_ACCOUNT}-${REGION}"
STACK_NAME="zipco-financial-risk-engine"
WORKGROUP="zipco-risk-analytics"
SOURCE_DATABASE="zipco_financial_risk"
BASELINE_ANALYTICS_DATABASE="zipco_financial_analytics"
RISK_DATABASE="zipco_financial_risk_engine"
MODEL_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFN_TEMPLATE="${SCRIPT_DIR}/zipco_risk_engine_infrastructure.json"
CONTRACT_FILE="${SCRIPT_DIR}/risk_model_contract.json"
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
VIEWS_FILE="$(mktemp)"
NAMED_QUERIES_FILE="$(mktemp)"
RISK_DISTRIBUTION_FILE="$(mktemp)"
KPI_RESULT_FILE="$(mktemp)"
EVIDENCE_FILE="${SCRIPT_DIR}/zipco_risk_engine_deployment_verification.json"

cleanup() {
  rm -f "$QUERY_RUNS_FILE" "$VALIDATION_RESULTS_FILE" "$ANALYTICS_RESULTS_FILE" \
    "$VIEWS_FILE" "$NAMED_QUERIES_FILE" "$RISK_DISTRIBUTION_FILE" "$KPI_RESULT_FILE"
}
trap cleanup EXIT

printf '[]\n' > "$RISK_DISTRIBUTION_FILE"
printf '{}\n' > "$KPI_RESULT_FILE"

for required in "$CFN_TEMPLATE" "$CONTRACT_FILE" "$VIEWS_DIR" "$VALIDATION_DIR" "$ANALYTICS_DIR"; do
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
KMS_KEY_ARN="$(aws kms describe-key --key-id alias/zipco-financial-platform --query 'KeyMetadata.Arn' --output text 2>/dev/null || true)"

SOURCE_TABLES_JSON="$(aws glue get-tables --database-name "$SOURCE_DATABASE" --query 'sort(TableList[?TableType!=`VIRTUAL_VIEW`].Name)' --output json)"
EXPECTED_SOURCE_TABLES='["zipco_v2_accounts","zipco_v2_categorized_transactions","zipco_v2_customers","zipco_v2_market_data","zipco_v2_transaction_categories","zipco_v2_transactions"]'
if ! jq -e --argjson expected "$EXPECTED_SOURCE_TABLES" 'sort == ($expected | sort)' <<< "$SOURCE_TABLES_JSON" >/dev/null; then
  echo "Source catalog contract failed. Expected $EXPECTED_SOURCE_TABLES but received $SOURCE_TABLES_JSON" >&2
  exit 5
fi

BASELINE_VIEWS_JSON="$(aws glue get-tables --database-name "$BASELINE_ANALYTICS_DATABASE" --query 'sort(TableList[?TableType==`VIRTUAL_VIEW`].Name)' --output json)"
EXPECTED_BASELINE_VIEWS='["v_account_risk_signals","v_customer_portfolio","v_monthly_risk_metrics","v_transaction_enriched"]'
if ! jq -e --argjson expected "$EXPECTED_BASELINE_VIEWS" 'sort == ($expected | sort)' <<< "$BASELINE_VIEWS_JSON" >/dev/null; then
  echo "Baseline analytics contract failed. Expected $EXPECTED_BASELINE_VIEWS but received $BASELINE_VIEWS_JSON" >&2
  exit 6
fi

WORKGROUP_JSON="$(aws athena get-work-group --work-group "$WORKGROUP" --output json)"
EXPECTED_RESULT_ENCRYPTION="SSE_S3"
if [[ -n "$KMS_KEY_ARN" && "$KMS_KEY_ARN" != "None" ]]; then
  EXPECTED_RESULT_ENCRYPTION="SSE_KMS"
fi
if ! jq -e --arg bucket "$BUCKET" --arg encryption "$EXPECTED_RESULT_ENCRYPTION" --arg kms_key "$KMS_KEY_ARN" '
  .WorkGroup.State == "ENABLED"
  and .WorkGroup.Configuration.EnforceWorkGroupConfiguration == true
  and .WorkGroup.Configuration.PublishCloudWatchMetricsEnabled == true
  and .WorkGroup.Configuration.ResultConfiguration.OutputLocation == ("s3://" + $bucket + "/athena/results/")
  and .WorkGroup.Configuration.ResultConfiguration.EncryptionConfiguration.EncryptionOption == $encryption
  and (if $encryption == "SSE_KMS" then .WorkGroup.Configuration.ResultConfiguration.EncryptionConfiguration.KmsKey == $kms_key else true end)
' <<< "$WORKGROUP_JSON" >/dev/null; then
  echo "Governed Athena workgroup verification failed." >&2
  exit 7
fi

echo "Uploading versioned risk-engine SQL and model contract"
aws s3 sync "$VIEWS_DIR" "s3://${BUCKET}/risk-engine/sql/v1/views/" --only-show-errors --exclude "*" --include "*.sql"
aws s3 sync "$VALIDATION_DIR" "s3://${BUCKET}/risk-engine/sql/v1/validation/" --only-show-errors --exclude "*" --include "*.sql"
aws s3 sync "$ANALYTICS_DIR" "s3://${BUCKET}/risk-engine/sql/v1/analytics/" --only-show-errors --exclude "*" --include "*.sql"
aws s3 cp "$CONTRACT_FILE" "s3://${BUCKET}/metadata/contracts/risk_engine/risk_model_contract_v1.json" \
  --only-show-errors --content-type application/json

echo "Deploying the risk database and six saved Athena queries"
aws cloudformation validate-template --template-body "file://${CFN_TEMPLATE}" >/dev/null

EXISTING_STACK_STATUS="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || true)"
case "$EXISTING_STACK_STATUS" in
  ROLLBACK_COMPLETE|REVIEW_IN_PROGRESS)
    echo "Removing the incomplete ZIPCO risk-engine stack before retry"
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
    ;;
esac

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$CFN_TEMPLATE" \
  --parameter-overrides "Environment=dev" "WorkGroupName=${WORKGROUP}" \
  --no-fail-on-empty-changeset

STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
case "$STACK_STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE) ;;
  *) echo "Unexpected stack status: $STACK_STATUS" >&2; exit 8 ;;
esac

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

echo "Creating six explainable financial-risk views"
for sql_file in "$VIEWS_DIR"/*.sql; do
  run_query "$sql_file" "$RISK_DATABASE" "VIEW_DDL" "$(basename "$sql_file" .sql)" >/dev/null
done

aws glue get-tables --database-name "$RISK_DATABASE" \
  --query 'sort_by(TableList[?TableType==`VIRTUAL_VIEW`],&Name)[].{Name:Name,TableType:TableType}' \
  --output json > "$VIEWS_FILE"
EXPECTED_RISK_VIEWS='["v_financial_kpis","v_monthly_risk_trends","v_risk_account_scores","v_risk_customer_scores","v_risk_transaction_features","v_risk_transaction_scores"]'
ACTUAL_RISK_VIEWS="$(jq '[.[].Name] | sort' "$VIEWS_FILE")"
if ! jq -e --argjson expected "$EXPECTED_RISK_VIEWS" 'sort == ($expected | sort)' <<< "$ACTUAL_RISK_VIEWS" >/dev/null; then
  echo "Risk view contract failed. Expected $EXPECTED_RISK_VIEWS but received $ACTUAL_RISK_VIEWS" >&2
  exit 9
fi

echo "Running ten risk-engine publication-gate validations"
for sql_file in "$VALIDATION_DIR"/*.sql; do
  label="$(basename "$sql_file" .sql)"
  query_id="$(run_query "$sql_file" "$RISK_DATABASE" "VALIDATION" "$label")"
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
    echo "Risk-engine validation failed: ${rule_id}; actual=${actual}; expected=${expected}; ${details}" >&2
    exit 10
  fi
done

echo "Executing six financial analytics and risk-review products"
for sql_file in "$ANALYTICS_DIR"/*.sql; do
  label="$(basename "$sql_file" .sql)"
  query_id="$(run_query "$sql_file" "$RISK_DATABASE" "ANALYTICS" "$label")"
  result="$(aws athena get-query-results --query-execution-id "$query_id" --max-items 1000 --output json)"
  data_rows="$(jq '([.ResultSet.Rows[]?] | length) - 1' <<< "$result")"
  if (( data_rows < 1 )); then
    echo "Analytics query returned no data rows: $label" >&2
    exit 11
  fi

  if [[ "$label" == "F01_financial_kpi_overview" ]]; then
    jq '{columns:(.ResultSet.ResultSetMetadata.ColumnInfo | map(.Name)),values:(.ResultSet.Rows[1].Data | map(.VarCharValue // null))}' \
      <<< "$result" > "$KPI_RESULT_FILE"
  fi
  if [[ "$label" == "F02_risk_distribution" ]]; then
    jq '[.ResultSet.Rows[1:][] | {
      entity_level:(.Data[0].VarCharValue // ""),
      risk_band:(.Data[1].VarCharValue // ""),
      entity_count:((.Data[2].VarCharValue // "0") | tonumber),
      exposure_value:((.Data[3].VarCharValue // "0") | tonumber),
      average_risk_score:((.Data[4].VarCharValue // "0") | tonumber)
    }]' <<< "$result" > "$RISK_DISTRIBUTION_FILE"
  fi

  jq -n \
    --arg query "$label" --arg query_execution_id "$query_id" --argjson returned_rows "$data_rows" \
    '{query:$query,query_execution_id:$query_execution_id,returned_rows:$returned_rows,status:"PASS"}' \
    >> "$ANALYTICS_RESULTS_FILE"
done

mapfile -t ALL_NAMED_QUERY_IDS < <(aws athena list-named-queries --work-group "$WORKGROUP" --query 'NamedQueryIds[]' --output text | tr '\t' '\n')
if (( ${#ALL_NAMED_QUERY_IDS[@]} == 0 )); then
  echo "No Athena saved queries were found in workgroup $WORKGROUP." >&2
  exit 12
fi
aws athena batch-get-named-query --named-query-ids "${ALL_NAMED_QUERY_IDS[@]}" --output json > "$NAMED_QUERIES_FILE"

EXPECTED_SAVED_QUERIES='["ZIPCO Risk Engine - Category Risk Profile","ZIPCO Risk Engine - Customer Review Queue","ZIPCO Risk Engine - Financial KPI Overview","ZIPCO Risk Engine - Monthly Risk Trends","ZIPCO Risk Engine - Risk Distribution","ZIPCO Risk Engine - Transaction Alert Queue"]'
ACTUAL_SAVED_QUERIES="$(jq '[.NamedQueries[] | select(.Name | startswith("ZIPCO Risk Engine - ")) | .Name] | sort' "$NAMED_QUERIES_FILE")"
if ! jq -e --argjson expected "$EXPECTED_SAVED_QUERIES" 'sort == ($expected | sort)' <<< "$ACTUAL_SAVED_QUERIES" >/dev/null; then
  echo "Saved-query contract failed. Expected $EXPECTED_SAVED_QUERIES but received $ACTUAL_SAVED_QUERIES" >&2
  exit 13
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
  --arg baseline_analytics_database "$BASELINE_ANALYTICS_DATABASE" \
  --arg risk_database "$RISK_DATABASE" \
  --arg model_version "$MODEL_VERSION" \
  --slurpfile views "$VIEWS_FILE" \
  --slurpfile query_runs "$QUERY_RUNS_FILE" \
  --slurpfile validation_results "$VALIDATION_RESULTS_FILE" \
  --slurpfile analytics_results "$ANALYTICS_RESULTS_FILE" \
  --slurpfile named_queries "$NAMED_QUERIES_FILE" \
  --slurpfile risk_distribution "$RISK_DISTRIBUTION_FILE" \
  --slurpfile financial_kpis "$KPI_RESULT_FILE" \
  '{
    status:$status,
    completed_at_utc:$completed_at_utc,
    pipeline_run_id:$pipeline_run_id,
    account_id:$account_id,
    caller_arn:$caller_arn,
    region:$region,
    bucket:$bucket,
    cloudformation:{stack_name:$stack_name,status:$stack_status},
    athena:{workgroup:$workgroup,source_database:$source_database,baseline_analytics_database:$baseline_analytics_database,risk_database:$risk_database},
    model:{name:"ZIPCO Explainable Financial Activity Risk Engine",version:$model_version,type:"deterministic_rules",usage:"portfolio monitoring and analyst prioritization only"},
    views:$views[0],
    saved_queries:[$named_queries[0].NamedQueries[] | select(.Name | startswith("ZIPCO Risk Engine - ")) | {id:.NamedQueryId,name:.Name}],
    validations:{status:"PASS",rules_passed:($validation_results|length),rules:$validation_results},
    analytics:{status:"PASS",queries_passed:($analytics_results|length),queries:$analytics_results},
    financial_kpis:$financial_kpis[0],
    risk_distribution:$risk_distribution[0],
    query_executions:$query_runs,
    total_data_scanned_bytes:([$query_runs[].data_scanned_bytes] | add)
  }' > "$EVIDENCE_FILE"

EVIDENCE_PREFIX="risk-engine/evidence/run_id=${RUN_ID}"
aws s3 cp "$EVIDENCE_FILE" "s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_risk_engine_deployment_verification.json" \
  --only-show-errors --content-type application/json
aws s3 cp "$EVIDENCE_FILE" "s3://${BUCKET}/metadata/contracts/risk_engine/zipco_risk_engine_deployment_verification_latest.json" \
  --only-show-errors --content-type application/json

VALIDATION_COUNT="$(jq '.validations.rules_passed' "$EVIDENCE_FILE")"
ANALYTICS_COUNT="$(jq '.analytics.queries_passed' "$EVIDENCE_FILE")"
VIEW_COUNT="$(jq '.views | length' "$EVIDENCE_FILE")"
SAVED_QUERY_COUNT="$(jq '.saved_queries | length' "$EVIDENCE_FILE")"
TOTAL_SCANNED="$(jq '.total_data_scanned_bytes' "$EVIDENCE_FILE")"
TX_CRITICAL="$(jq -r '.risk_distribution[] | select(.entity_level == "TRANSACTION" and .risk_band == "CRITICAL") | .entity_count' "$EVIDENCE_FILE")"
ACCOUNT_CRITICAL="$(jq -r '.risk_distribution[] | select(.entity_level == "ACCOUNT" and .risk_band == "CRITICAL") | .entity_count' "$EVIDENCE_FILE")"
CUSTOMER_CRITICAL="$(jq -r '.risk_distribution[] | select(.entity_level == "CUSTOMER" and .risk_band == "CRITICAL") | .entity_count' "$EVIDENCE_FILE")"

echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Risk model: ZIPCO Explainable Financial Activity Risk Engine v${MODEL_VERSION}"
echo "Athena workgroup: $WORKGROUP"
echo "Risk database: $RISK_DATABASE"
echo "Risk views: ${VIEW_COUNT}/6"
echo "Validation status: PASS (${VALIDATION_COUNT}/10)"
echo "Financial analytics queries: PASS (${ANALYTICS_COUNT}/6)"
echo "Saved risk queries: ${SAVED_QUERY_COUNT}/6"
echo "Critical entities: transactions=${TX_CRITICAL}, accounts=${ACCOUNT_CRITICAL}, customers=${CUSTOMER_CRITICAL}"
echo "Total data scanned (bytes): $TOTAL_SCANNED"
echo "Evidence: s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_risk_engine_deployment_verification.json"
