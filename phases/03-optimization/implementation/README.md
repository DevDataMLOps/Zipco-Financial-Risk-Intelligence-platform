# Reproducible Implementation

This directory contains the current implementation used to create the ZIPCO observability and Athena performance phase:

- `deploy_and_run_zipco_observability.sh` deploys the stack, executes all benchmark queries, applies correctness and performance gates, publishes metrics, verifies monitoring, and uploads evidence.
- `zipco_observability_infrastructure.json` defines the CloudWatch dashboard, alarms, event rules, failure log group, metric filter, and benchmark database.
- `performance_contract.json` is the pre-execution input contract. Its `READY_FOR_AWS_EXECUTION` status is intentionally preserved because it describes the state before a run.
- `benchmark/` contains the baseline DDL and four SQL strategies.

The later verified AWS outcome is represented separately in `../contracts/zipco_verified_optimization_benchmark.json` and `../evidence/aws_optimization_benchmark_verification.json`.

