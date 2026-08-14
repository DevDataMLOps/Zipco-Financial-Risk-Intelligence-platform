#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ACCOUNT="825999268272"
REGION="us-east-2"
BUCKET="zipco-financial-platform-${EXPECTED_ACCOUNT}-${REGION}"
STACK_NAME="zipco-observability-performance"
WORKGROUP="zipco-risk-analytics"
SOURCE_DATABASE="zipco_financial_risk"
BENCHMARK_DATABASE="zipco_performance_benchmark"
GLUE_JOB="zipco-relational-v2-validation-transform"
GLUE_CRAWLER="zipco-relational-v2-curated-crawler"
DASHBOARD_NAME="zipco-financial-platform-operations"
FAILURE_LOG_GROUP="/aws/events/zipco-financial-platform/failures"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFN_TEMPLATE="${SCRIPT_DIR}/zipco_observability_infrastructure.json"
BENCHMARK_DIR="${SCRIPT_DIR}/benchmark"
CONTRACT_FILE="${SCRIPT_DIR}/performance_contract.json"
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-cloudshell"
ITERATIONS=3

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

QUERY_RUNS_FILE="$(mktemp)"
BENCHMARK_RUNS_FILE="$(mktemp)"
STRATEGY_SUMMARY_FILE="$(mktemp)"
METRIC_DATA_FILE="$(mktemp)"
TRANSACTION_PARTITIONS_FILE="$(mktemp)"
MARKET_PARTITIONS_FILE="$(mktemp)"
REPORT_FILE="${SCRIPT_DIR}/zipco_athena_performance_benchmark.json"
REPORT_CSV="${SCRIPT_DIR}/zipco_athena_performance_benchmark.csv"
EVIDENCE_FILE="${SCRIPT_DIR}/zipco_observability_deployment_verification.json"

cleanup() {
  rm -f "$QUERY_RUNS_FILE" "$BENCHMARK_RUNS_FILE" "$STRATEGY_SUMMARY_FILE" \
    "$METRIC_DATA_FILE" "$TRANSACTION_PARTITIONS_FILE" "$MARKET_PARTITIONS_FILE"
}
trap cleanup EXIT

for required in "$CFN_TEMPLATE" "$CONTRACT_FILE" "$BENCHMARK_DIR/00_create_transactions_csv.sql" \
  "$BENCHMARK_DIR/B01_csv_full.sql" "$BENCHMARK_DIR/B02_parquet_full.sql" \
  "$BENCHMARK_DIR/B03_csv_2023.sql" "$BENCHMARK_DIR/B04_parquet_partitioned_2023.sql"; do
  [[ -f "$required" ]] || { echo "Missing required artifact: $required" >&2; exit 2; }
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
aws athena get-work-group --work-group "$WORKGROUP" >/dev/null
aws glue get-job --job-name "$GLUE_JOB" >/dev/null
aws glue get-crawler --name "$GLUE_CRAWLER" >/dev/null
EXPECTED_SOURCE_TABLES='["zipco_v2_accounts","zipco_v2_categorized_transactions","zipco_v2_customers","zipco_v2_market_data","zipco_v2_transaction_categories","zipco_v2_transactions"]'
SOURCE_TABLES="$(aws glue get-tables --database-name "$SOURCE_DATABASE" --query 'sort(TableList[?TableType!=`VIRTUAL_VIEW`].Name)' --output json)"
if ! jq -e --argjson expected "$EXPECTED_SOURCE_TABLES" 'sort == ($expected | sort)' <<< "$SOURCE_TABLES" >/dev/null; then
  echo "Source table contract failed: $SOURCE_TABLES" >&2
  exit 5
fi

echo "Uploading versioned benchmark SQL and monitoring contract"
aws s3 sync "$BENCHMARK_DIR" "s3://${BUCKET}/performance/sql/v1/" --only-show-errors --sse AES256 --exclude "*" --include "*.sql"
aws s3 cp "$CONTRACT_FILE" "s3://${BUCKET}/metadata/contracts/relational_v2/performance_contract.json" --only-show-errors --sse AES256 --content-type application/json

echo "Deploying CloudWatch dashboard, event monitoring, alarms, and benchmark database"
aws cloudformation validate-template --template-body "file://${CFN_TEMPLATE}" >/dev/null

# A stack that rolled back after a failed first deployment cannot be updated.
# Remove only this exact project stack so the corrected template can be retried safely.
EXISTING_STACK_STATUS="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || true)"
if [[ "$EXISTING_STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
  echo "Removing the rolled-back ZIPCO observability stack before retry"
  aws cloudformation delete-stack --stack-name "$STACK_NAME"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
fi

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$CFN_TEMPLATE" \
  --parameter-overrides "Environment=dev" \
  --capabilities CAPABILITY_AUTO_EXPAND \
  --no-fail-on-empty-changeset

STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)"
case "$STACK_STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE) ;;
  *) echo "Unexpected stack status: $STACK_STATUS" >&2; exit 6 ;;
esac

run_query() {
  local sql="$1"
  local database="$2"
  local category="$3"
  local label="$4"
  local disable_reuse="$5"
  local query_id state execution reason
  local -a start_arguments

  start_arguments=(
    athena start-query-execution
    --query-string "$sql"
    --query-execution-context "Database=${database},Catalog=AwsDataCatalog"
    --work-group "$WORKGROUP"
  )
  if [[ "$disable_reuse" == "true" ]]; then
    start_arguments+=(--result-reuse-configuration '{"ResultReuseByAgeConfiguration":{"Enabled":false}}')
  fi
  start_arguments+=(--query QueryExecutionId --output text)

  query_id="$(aws "${start_arguments[@]}")"
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
    --arg query_execution_id "$query_id" \
    --arg state "$state" \
    --arg database "$database" \
    --arg output_location "$(jq -r '.QueryExecution.ResultConfiguration.OutputLocation // ""' <<< "$execution")" \
    --argjson data_scanned_bytes "$(jq -r '.QueryExecution.Statistics.DataScannedInBytes // 0' <<< "$execution")" \
    --argjson engine_execution_ms "$(jq -r '.QueryExecution.Statistics.EngineExecutionTimeInMillis // 0' <<< "$execution")" \
    --argjson total_execution_ms "$(jq -r '.QueryExecution.Statistics.TotalExecutionTimeInMillis // 0' <<< "$execution")" \
    '{category:$category,label:$label,query_execution_id:$query_execution_id,state:$state,database:$database,output_location:$output_location,data_scanned_bytes:$data_scanned_bytes,engine_execution_ms:$engine_execution_ms,total_execution_ms:$total_execution_ms}' \
    >> "$QUERY_RUNS_FILE"

  echo "${category}: ${label} -> SUCCEEDED" >&2
  printf '%s' "$query_id"
}

DDL_SQL="$(<"$BENCHMARK_DIR/00_create_transactions_csv.sql")"
DDL_SQL="${DDL_SQL//__BUCKET__/$BUCKET}"
run_query "$DDL_SQL" "$BENCHMARK_DATABASE" "DDL" "create_transactions_csv_baseline" "false" >/dev/null

TRANSACTIONS_TABLE="$(aws glue get-table --database-name "$SOURCE_DATABASE" --name zipco_v2_transactions --output json)"
PARTITION_TYPE="$(jq -r '.Table.PartitionKeys[] | select((.Name | ascii_downcase) == "transactionyear") | .Type' <<< "$TRANSACTIONS_TABLE")"
if [[ -z "$PARTITION_TYPE" || "$PARTITION_TYPE" == "null" ]]; then
  echo "TransactionYear partition key was not found in the Glue Catalog." >&2
  exit 7
fi
case "${PARTITION_TYPE,,}" in
  tinyint|smallint|int|integer|bigint) PARTITION_PREDICATE="TransactionYear = 2023" ;;
  *) PARTITION_PREDICATE="TransactionYear = '2023'" ;;
esac

aws glue get-partitions --database-name "$SOURCE_DATABASE" --table-name zipco_v2_transactions --output json > "$TRANSACTION_PARTITIONS_FILE"
aws glue get-partitions --database-name "$SOURCE_DATABASE" --table-name zipco_v2_market_data --output json > "$MARKET_PARTITIONS_FILE"
TRANSACTION_PARTITION_COUNT="$(jq '.Partitions | length' "$TRANSACTION_PARTITIONS_FILE")"
MARKET_PARTITION_COUNT="$(jq '.Partitions | length' "$MARKET_PARTITIONS_FILE")"
if (( TRANSACTION_PARTITION_COUNT < 1 || MARKET_PARTITION_COUNT < 1 )); then
  echo "Expected year partitions were not found for transactions and market data." >&2
  exit 8
fi

BENCHMARK_NAMES=(csv_full parquet_full csv_2023 parquet_partitioned_2023)
BENCHMARK_FILES=(B01_csv_full.sql B02_parquet_full.sql B03_csv_2023.sql B04_parquet_partitioned_2023.sql)
BENCHMARK_FORMATS=(CSV Parquet CSV Parquet)
BENCHMARK_SCOPES=(full full year_2023 year_2023)

echo "Running four benchmark strategies with ${ITERATIONS} uncached iterations each"
for index in "${!BENCHMARK_NAMES[@]}"; do
  benchmark="${BENCHMARK_NAMES[$index]}"
  sql_file="${BENCHMARK_DIR}/${BENCHMARK_FILES[$index]}"
  format="${BENCHMARK_FORMATS[$index]}"
  scope="${BENCHMARK_SCOPES[$index]}"
  base_sql="$(<"$sql_file")"
  base_sql="${base_sql//__PARTITION_PREDICATE__/$PARTITION_PREDICATE}"

  for iteration in $(seq 1 "$ITERATIONS"); do
    sql="-- zipco_benchmark run_id=${RUN_ID} strategy=${benchmark} iteration=${iteration}"$'\n'"${base_sql}"
    query_id="$(run_query "$sql" "$BENCHMARK_DATABASE" "BENCHMARK" "${benchmark}_${iteration}" "true")"
    execution="$(aws athena get-query-execution --query-execution-id "$query_id" --output json)"
    result="$(aws athena get-query-results --query-execution-id "$query_id" --max-items 10 --output json)"
    result_rows="$(jq '(.ResultSet.Rows | length) - 1' <<< "$result")"
    result_signature="$(jq -c '.ResultSet.Rows[1:] | map(.Data | map(.VarCharValue // ""))' <<< "$result" | sha256sum | awk '{print $1}')"
    if [[ "$result_rows" != "3" ]]; then
      echo "Benchmark $benchmark returned $result_rows rows; expected 3 transaction types." >&2
      exit 9
    fi

    jq -n \
      --arg benchmark "$benchmark" \
      --arg format "$format" \
      --arg scope "$scope" \
      --arg sql_file "$(basename "$sql_file")" \
      --arg sql_sha256 "$(sha256sum "$sql_file" | awk '{print $1}')" \
      --arg query_execution_id "$query_id" \
      --arg result_signature "$result_signature" \
      --argjson iteration "$iteration" \
      --argjson result_rows "$result_rows" \
      --argjson data_scanned_bytes "$(jq -r '.QueryExecution.Statistics.DataScannedInBytes // 0' <<< "$execution")" \
      --argjson engine_execution_ms "$(jq -r '.QueryExecution.Statistics.EngineExecutionTimeInMillis // 0' <<< "$execution")" \
      --argjson total_execution_ms "$(jq -r '.QueryExecution.Statistics.TotalExecutionTimeInMillis // 0' <<< "$execution")" \
      '{benchmark:$benchmark,format:$format,scope:$scope,iteration:$iteration,sql_file:$sql_file,sql_sha256:$sql_sha256,query_execution_id:$query_execution_id,result_rows:$result_rows,result_signature:$result_signature,data_scanned_bytes:$data_scanned_bytes,engine_execution_ms:$engine_execution_ms,total_execution_ms:$total_execution_ms}' \
      >> "$BENCHMARK_RUNS_FILE"
  done
done

jq -s '
  sort_by(.benchmark)
  | group_by(.benchmark)
  | map({
      benchmark: .[0].benchmark,
      format: .[0].format,
      scope: .[0].scope,
      iterations: length,
      result_rows: (map(.result_rows) | unique),
      result_signatures: (map(.result_signature) | unique),
      average_data_scanned_bytes: (map(.data_scanned_bytes) | add / length),
      minimum_data_scanned_bytes: (map(.data_scanned_bytes) | min),
      maximum_data_scanned_bytes: (map(.data_scanned_bytes) | max),
      average_engine_execution_ms: (map(.engine_execution_ms) | add / length),
      average_total_execution_ms: (map(.total_execution_ms) | add / length)
    })
' "$BENCHMARK_RUNS_FILE" > "$STRATEGY_SUMMARY_FILE"

if ! jq -e --argjson iterations "$ITERATIONS" 'all(.[]; .iterations == $iterations and (.result_signatures | length) == 1 and .result_rows == [3])' "$STRATEGY_SUMMARY_FILE" >/dev/null; then
  echo "Benchmark repeatability gate failed." >&2
  exit 10
fi

CSV_FULL_SIGNATURE="$(jq -r '.[] | select(.benchmark == "csv_full") | .result_signatures[0]' "$STRATEGY_SUMMARY_FILE")"
PARQUET_FULL_SIGNATURE="$(jq -r '.[] | select(.benchmark == "parquet_full") | .result_signatures[0]' "$STRATEGY_SUMMARY_FILE")"
CSV_2023_SIGNATURE="$(jq -r '.[] | select(.benchmark == "csv_2023") | .result_signatures[0]' "$STRATEGY_SUMMARY_FILE")"
PARQUET_2023_SIGNATURE="$(jq -r '.[] | select(.benchmark == "parquet_partitioned_2023") | .result_signatures[0]' "$STRATEGY_SUMMARY_FILE")"
if [[ "$CSV_FULL_SIGNATURE" != "$PARQUET_FULL_SIGNATURE" || "$CSV_2023_SIGNATURE" != "$PARQUET_2023_SIGNATURE" ]]; then
  echo "CSV and Parquet query results did not reconcile." >&2
  exit 11
fi

if ! jq -e '
  (map(select(.benchmark == "csv_full"))[0].average_data_scanned_bytes) as $csv_full
  | (map(select(.benchmark == "parquet_full"))[0].average_data_scanned_bytes) as $parquet_full
  | (map(select(.benchmark == "parquet_partitioned_2023"))[0].average_data_scanned_bytes) as $partitioned
  | $parquet_full > 0 and $parquet_full < $csv_full and $partitioned >= 0 and $partitioned < $parquet_full
' "$STRATEGY_SUMMARY_FILE" >/dev/null; then
  echo "Expected Parquet and partition-pruning scan reductions were not observed." >&2
  exit 12
fi

COMPLETED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
jq -n \
  --arg status "PASS" \
  --arg completed_at_utc "$COMPLETED_AT" \
  --arg run_id "$RUN_ID" \
  --arg workgroup "$WORKGROUP" \
  --arg source_database "$SOURCE_DATABASE" \
  --arg benchmark_database "$BENCHMARK_DATABASE" \
  --arg partition_key_type "$PARTITION_TYPE" \
  --arg partition_predicate "$PARTITION_PREDICATE" \
  --argjson iterations_per_strategy "$ITERATIONS" \
  --argjson transaction_partitions "$TRANSACTION_PARTITION_COUNT" \
  --argjson market_partitions "$MARKET_PARTITION_COUNT" \
  --slurpfile strategy_summary "$STRATEGY_SUMMARY_FILE" \
  --slurpfile benchmark_runs "$BENCHMARK_RUNS_FILE" \
  '{
    status:$status,
    completed_at_utc:$completed_at_utc,
    run_id:$run_id,
    workgroup:$workgroup,
    source_database:$source_database,
    benchmark_database:$benchmark_database,
    iterations_per_strategy:$iterations_per_strategy,
    result_reuse_enabled:false,
    partitions:{transactions:$transaction_partitions,market_data:$market_partitions,transaction_year_type:$partition_key_type,predicate:$partition_predicate},
    reconciliation:{full_scan:"PASS",year_2023:"PASS"},
    strategy_summary:$strategy_summary[0],
    comparisons:{
      csv_to_parquet_full_scan_reduction_pct:(100 * (1 - (($strategy_summary[0] | map(select(.benchmark == "parquet_full"))[0].average_data_scanned_bytes) / ($strategy_summary[0] | map(select(.benchmark == "csv_full"))[0].average_data_scanned_bytes)))),
      parquet_full_to_partitioned_2023_scan_reduction_pct:(100 * (1 - (($strategy_summary[0] | map(select(.benchmark == "parquet_partitioned_2023"))[0].average_data_scanned_bytes) / ($strategy_summary[0] | map(select(.benchmark == "parquet_full"))[0].average_data_scanned_bytes))))
    },
    runs:$benchmark_runs
  }' > "$REPORT_FILE"

jq -r '
  (["strategy","format","scope","iterations","avg_scanned_bytes","min_scanned_bytes","max_scanned_bytes","avg_engine_ms","avg_total_ms"] | @csv),
  (.strategy_summary[] | [.benchmark,.format,.scope,.iterations,.average_data_scanned_bytes,.minimum_data_scanned_bytes,.maximum_data_scanned_bytes,.average_engine_execution_ms,.average_total_execution_ms] | @csv)
' "$REPORT_FILE" > "$REPORT_CSV"

jq '[
  .strategy_summary[]
  | {MetricName:"AverageDataScannedBytes",Dimensions:[{Name:"Strategy",Value:.benchmark}],Value:.average_data_scanned_bytes,Unit:"Bytes"},
    {MetricName:"AverageEngineExecutionTimeMs",Dimensions:[{Name:"Strategy",Value:.benchmark}],Value:.average_engine_execution_ms,Unit:"Milliseconds"}
] + [
  {MetricName:"ScanReductionPercent",Dimensions:[{Name:"Comparison",Value:"csv_to_parquet_full"}],Value:.comparisons.csv_to_parquet_full_scan_reduction_pct,Unit:"Percent"},
  {MetricName:"ScanReductionPercent",Dimensions:[{Name:"Comparison",Value:"parquet_full_to_partitioned_2023"}],Value:.comparisons.parquet_full_to_partitioned_2023_scan_reduction_pct,Unit:"Percent"}
]' "$REPORT_FILE" > "$METRIC_DATA_FILE"
aws cloudwatch put-metric-data --namespace "ZIPCO/Performance" --metric-data "file://${METRIC_DATA_FILE}"

aws cloudwatch get-dashboard --dashboard-name "$DASHBOARD_NAME" >/dev/null
ALARM_COUNT="$(aws cloudwatch describe-alarms --alarm-names zipco-pipeline-failure-events zipco-athena-successful-dml-scan-spike zipco-glue-failed-spark-tasks --query 'length(MetricAlarms)' --output text)"
if [[ "$ALARM_COUNT" != "3" ]]; then
  echo "Expected three CloudWatch alarms but found $ALARM_COUNT." >&2
  exit 13
fi
aws logs describe-log-groups --log-group-name-prefix "$FAILURE_LOG_GROUP" --query 'logGroups[?logGroupName==`/aws/events/zipco-financial-platform/failures`]' --output json | jq -e 'length == 1' >/dev/null

RULE_NAMES=(zipco-glue-job-failures zipco-glue-crawler-failures zipco-athena-query-failures)
RULE_EVENTS=(
  '{"version":"0","id":"00000000-0000-0000-0000-000000000001","detail-type":"Glue Job State Change","source":"aws.glue","account":"825999268272","time":"2026-08-13T00:00:00Z","region":"us-east-2","resources":[],"detail":{"jobName":"zipco-relational-v2-validation-transform","state":"FAILED"}}'
  '{"version":"0","id":"00000000-0000-0000-0000-000000000002","detail-type":"Glue Crawler State Change","source":"aws.glue","account":"825999268272","time":"2026-08-13T00:00:00Z","region":"us-east-2","resources":[],"detail":{"crawlerName":"zipco-relational-v2-curated-crawler","state":"Failed"}}'
  '{"version":"0","id":"00000000-0000-0000-0000-000000000003","detail-type":"Athena Query State Change","source":"aws.athena","account":"825999268272","time":"2026-08-13T00:00:00Z","region":"us-east-2","resources":[],"detail":{"workgroupName":"zipco-risk-analytics","currentState":"FAILED","queryExecutionId":"00000000-0000-0000-0000-000000000004"}}'
)
for index in "${!RULE_NAMES[@]}"; do
  rule="${RULE_NAMES[$index]}"
  state="$(aws events describe-rule --name "$rule" --query State --output text)"
  targets="$(aws events list-targets-by-rule --rule "$rule" --query 'length(Targets)' --output text)"
  pattern="$(aws events describe-rule --name "$rule" --query EventPattern --output text)"
  matches="$(aws events test-event-pattern --event-pattern "$pattern" --event "${RULE_EVENTS[$index]}" --query Result --output text)"
  if [[ "$state" != "ENABLED" || "$targets" != "1" || "${matches,,}" != "true" ]]; then
    echo "EventBridge verification failed for $rule: state=$state targets=$targets matches=$matches" >&2
    exit 14
  fi
done

CSV_TO_PARQUET_REDUCTION="$(jq '.comparisons.csv_to_parquet_full_scan_reduction_pct' "$REPORT_FILE")"
PARTITION_REDUCTION="$(jq '.comparisons.parquet_full_to_partitioned_2023_scan_reduction_pct' "$REPORT_FILE")"
DASHBOARD_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"

jq -n \
  --arg status "DEPLOYED_RUN_AND_VERIFIED" \
  --arg completed_at_utc "$COMPLETED_AT" \
  --arg run_id "$RUN_ID" \
  --arg account_id "$ACTUAL_ACCOUNT" \
  --arg caller_arn "$CALLER_ARN" \
  --arg region "$REGION" \
  --arg bucket "$BUCKET" \
  --arg stack_name "$STACK_NAME" \
  --arg stack_status "$STACK_STATUS" \
  --arg dashboard_name "$DASHBOARD_NAME" \
  --arg dashboard_url "$DASHBOARD_URL" \
  --arg failure_log_group "$FAILURE_LOG_GROUP" \
  --argjson alarm_count "$ALARM_COUNT" \
  --argjson event_rule_count "${#RULE_NAMES[@]}" \
  --slurpfile benchmark "$REPORT_FILE" \
  --slurpfile query_runs "$QUERY_RUNS_FILE" \
  '{
    status:$status,
    completed_at_utc:$completed_at_utc,
    run_id:$run_id,
    account_id:$account_id,
    caller_arn:$caller_arn,
    region:$region,
    bucket:$bucket,
    cloudformation:{stack_name:$stack_name,status:$stack_status},
    dashboard:{name:$dashboard_name,url:$dashboard_url,status:"VERIFIED"},
    monitoring:{status:"VERIFIED",failure_log_group:$failure_log_group,event_rules:$event_rule_count,alarms:$alarm_count},
    benchmark:$benchmark[0],
    query_executions:$query_runs
  }' > "$EVIDENCE_FILE"

EVIDENCE_PREFIX="performance/evidence/run_id=${RUN_ID}"
aws s3 cp "$REPORT_FILE" "s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_athena_performance_benchmark.json" --only-show-errors --sse AES256 --content-type application/json
aws s3 cp "$REPORT_CSV" "s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_athena_performance_benchmark.csv" --only-show-errors --sse AES256 --content-type text/csv
aws s3 cp "$EVIDENCE_FILE" "s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_observability_deployment_verification.json" --only-show-errors --sse AES256 --content-type application/json
aws s3 cp "$EVIDENCE_FILE" "s3://${BUCKET}/metadata/contracts/relational_v2/zipco_observability_deployment_verification.json" --only-show-errors --sse AES256 --content-type application/json
aws s3api head-object --bucket "$BUCKET" --key "${EVIDENCE_PREFIX}/zipco_observability_deployment_verification.json" >/dev/null

echo
echo "Status: DEPLOYED_RUN_AND_VERIFIED"
echo "Dashboard: $DASHBOARD_NAME"
echo "Dashboard URL: $DASHBOARD_URL"
echo "Monitoring rules: ${#RULE_NAMES[@]}/3"
echo "CloudWatch alarms: ${ALARM_COUNT}/3"
echo "Benchmark strategies: 4/4 (${ITERATIONS} uncached iterations each)"
echo "Result reconciliation: PASS"
printf 'CSV to Parquet full-scan reduction: %.2f%%\n' "$CSV_TO_PARQUET_REDUCTION"
printf 'Parquet full to partition-pruned 2023 reduction: %.2f%%\n' "$PARTITION_REDUCTION"
echo "Partitions verified: transactions=${TRANSACTION_PARTITION_COUNT}, market_data=${MARKET_PARTITION_COUNT}"
echo "Evidence: s3://${BUCKET}/${EVIDENCE_PREFIX}/zipco_observability_deployment_verification.json"
