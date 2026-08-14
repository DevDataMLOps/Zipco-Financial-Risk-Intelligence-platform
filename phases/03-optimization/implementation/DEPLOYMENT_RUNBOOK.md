# ZIPCO Observability and Athena Performance Benchmark

## Target

- AWS account: `825999268272`
- Region: `us-east-2` (Ohio)
- Existing S3 bucket: `zipco-financial-platform-825999268272-us-east-2`
- Athena workgroup: `zipco-risk-analytics`
- CloudWatch dashboard: `zipco-financial-platform-operations`

No additional S3 bucket is created.

## What this phase implements

### Operational dashboard

The CloudWatch dashboard brings together:

- Active pipeline alarms.
- Measured CSV, Parquet, and partition-pruned scan volume.
- Measured Athena engine execution time.
- Athena workgroup scan volume and query latency.
- Glue completed and failed Spark tasks.
- Captured Glue, crawler, and Athena failure events.

### Monitoring

Three EventBridge rules capture:

- Failed, timed-out, or stopped ZIPCO Glue jobs.
- Failed ZIPCO crawler runs.
- Failed queries in the governed Athena workgroup.

Failure events are retained for 30 days in `/aws/events/zipco-financial-platform/failures`. Three CloudWatch alarms monitor pipeline failure events, Athena scan spikes, and failed Glue Spark tasks.

The alarms appear in CloudWatch but do not send email because no notification recipient was supplied. Email or SMS notification can be added later through SNS.

### Performance benchmark

The benchmark runs four strategies three times each with Athena result reuse disabled:

1. CSV full scan.
2. Parquet full scan.
3. CSV filter for 2023.
4. Parquet filter for 2023 with an explicit partition predicate.

Every run records bytes scanned, engine time, total time, result rows, and a result signature. Deployment fails unless CSV and Parquet results reconcile and both expected scan reductions are measured.

The CSV table exists only in the isolated `zipco_performance_benchmark` database. The six-table production Glue contract remains unchanged.

## CloudShell deployment

Upload `zipco_observability_performance_bundle_v2.zip` to the Ohio CloudShell session and run:

```bash
unzip -o zipco_observability_performance_bundle_v2.zip
chmod +x zipco-observability-performance/deploy_and_run_zipco_observability.sh
./zipco-observability-performance/deploy_and_run_zipco_observability.sh
```

Keep CloudShell open until the prompt returns. Expected completion:

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Monitoring rules: 3/3
CloudWatch alarms: 3/3
Benchmark strategies: 4/4 (3 uncached iterations each)
Result reconciliation: PASS
```

The final output also reports the measured scan-reduction percentages and verified partition counts.

## Costs

This phase can incur small Athena query, CloudWatch dashboard, alarm, log-ingestion, and custom-metric charges. QuickSight is intentionally not enabled by this bundle.
