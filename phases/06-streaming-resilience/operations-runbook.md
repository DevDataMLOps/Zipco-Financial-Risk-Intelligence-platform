# Streaming Operations Runbook

## Health signals

The composite alarm `zipco-stream-health-dev` summarizes four actionable failures:

| Alarm | Meaning | First checks |
|---|---|---|
| Firehose S3 delivery failure | Curated S3 delivery success fell below 100% | Firehose error log, S3/KMS access, Lambda result status |
| Firehose data freshness | Oldest buffered event exceeded 15 minutes | Firehose error log, S3/KMS access, Lambda duration/errors |
| Firehose throttled records | Firehose could not keep pace with source input | Stream limits, active partitions, destination latency |
| Lambda transform errors | Invocation-level code/runtime failure | Lambda logs, timeout, permissions, last deployment artifact |

Expected business-invalid test records do not raise the Lambda error alarm because the function returns a per-record `ProcessingFailed` result. They are diagnosed from `streaming/errors/` and the batch summary log.

## Incident sequence

1. Record the alarm name, timestamp, region, stream name, and most recent deployment run ID.
2. Open `zipco-financial-platform-streaming-dev` and determine whether ingress, transform, or delivery is impaired.
3. Review sanitized Lambda batch summaries and Firehose delivery logs.
4. Confirm raw backup objects continue to arrive before changing or replaying data.
5. Inspect a bounded sample from the error prefix; do not paste full financial payloads into tickets or chat.
6. Correct the contract, producer, permissions, or transform defect through version-controlled deployment.
7. Run replay in dry-run mode and review the selected count/fingerprint.
8. Obtain change approval, then repeat with `--execute`.
9. Confirm curated delivery, alarm recovery, and evidence publication.

## Replay commands

Dry run:

```bash
python3 replay_stream_records.py \
  --bucket "$DATA_BUCKET" \
  --delivery-stream-name zipco-streaming-transactions-dev \
  --run-id <run-id> \
  --max-records 100
```

Approved execution:

```bash
python3 replay_stream_records.py \
  --bucket "$DATA_BUCKET" \
  --delivery-stream-name zipco-streaming-transactions-dev \
  --run-id <run-id> \
  --max-records 100 \
  --execute
```

The replay can introduce duplicates. Downstream reconciliation must use `transaction_id` before publishing business totals.

## Rollback

Redeploy the previously known Lambda artifact key and CloudFormation revision. Do not delete the raw, error, or evidence prefixes during an incident. If the stream must be stopped, stop producers first and allow Firehose buffers to drain before deleting infrastructure.
