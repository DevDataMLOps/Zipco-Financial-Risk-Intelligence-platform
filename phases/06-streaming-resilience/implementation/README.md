# Phase 6 Implementation

This directory contains the deployable CloudWatch, streaming, and resilience layer.

| File | Purpose |
|---|---|
| `zipco_streaming_resilience_infrastructure.json` | CloudFormation for Firehose Direct PUT, Lambda, IAM, CloudWatch, SNS, raw backup, error isolation, and dashboard |
| `firehose_transform.py` | Per-record contract validation, normalization, and event-time partition metadata |
| `publish_test_events.py` | Deterministic publisher for valid and expected-invalid verification events |
| `verify_streaming_resilience.py` | AWS state and S3 delivery verifier for the 20 mandatory controls |
| `replay_stream_records.py` | Dry-run-by-default bounded replay utility for raw backup events |
| `deploy_and_verify_zipco_streaming_resilience.sh` | Idempotent CloudShell deployment, test, verification, and evidence workflow |

The automation requires the Phase 5 customer-managed key alias `alias/zipco-financial-platform` and the existing ZIPCO S3 bucket. It does not modify historical objects or enable Lake Formation on the established analytics databases.

Run the full workflow from AWS CloudShell:

```bash
chmod +x deploy_and_verify_zipco_streaming_resilience.sh
./deploy_and_verify_zipco_streaming_resilience.sh
```

See [DEPLOYMENT_RUNBOOK.md](DEPLOYMENT_RUNBOOK.md) before deployment.
