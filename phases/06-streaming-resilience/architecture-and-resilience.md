# Streaming Architecture and Resilience Design

## Design objective

The batch platform already proves correctness, analytics, performance, and governance. This phase adds a small, inspectable near-real-time path without weakening those controls or claiming that a portfolio workload is a globally distributed banking system.

## Component responsibilities

| Component | Responsibility | Failure behavior |
|---|---|---|
| Amazon Data Firehose | Accept Direct PUT records, invoke transformation, buffer, retry, and write S3 | Delivery success, age, and throttling are alarmed; source backup is enabled |
| Lambda transformer | Enforce schema v2.1.0, normalize safe fields, and return partition keys | Invalid records return `ProcessingFailed`; invocation errors remain distinct |
| S3 raw backup | Preserve every source event independent of transform outcome | Forms the durable recovery source and lineage boundary |
| S3 curated | Store validated newline JSON in event-time partitions | Downstream consumers must de-duplicate on `transaction_id` |
| S3 error path | Isolate records Firehose could not transform or deliver | Error type is encoded in the prefix for triage |
| CloudWatch | Expose ingestion, delivery, freshness, backup, transform, and alarm health | Missing data does not create false incidents on an idle demo stream |
| SNS | Route alarm/OK transitions to an approved endpoint | Topic uses a dedicated rotating customer-managed key whose policy permits CloudWatch; email is optional and must be confirmed |

## Reliability patterns

### At-least-once and idempotency

Firehose and operator replay can deliver a record more than once. The contract therefore makes `transaction_id` the idempotency key. Any future Glue, Athena, Iceberg, database, or API consumer must use that key when producing a latest-state or unique-event view.

### Backpressure and freshness

Firehose Direct PUT capacity is finite. Firehose throttled records alarm on any non-zero observation, and delivery success alarms when it falls below one. `DeliveryToS3.DataFreshness` alarms only after three consecutive one-minute periods above 900 seconds, the configured maximum buffering window.

### Poison records

Business-invalid data is not silently dropped and does not crash the whole Lambda batch. Each invalid record returns `ProcessingFailed`, keeping the transport available while Firehose sends the failed payload to the S3 error path. Lambda invocation errors are monitored separately because they indicate a code or runtime problem rather than expected data rejection.

### Recovery and replay

The raw backup is the recovery source. The replay utility:

- defaults to inspection-only mode;
- can filter on the deployment `run_id`;
- caps one operation at 500 records;
- creates a deterministic replay-batch fingerprint;
- writes only after `--execute` is supplied.

Replay does not mutate or delete source objects. Operators must record approval, selection criteria, and the resulting batch fingerprint in an incident or change record.

## Recovery objectives

| Objective | Target | Evidence boundary |
|---|---|---|
| RPO | Every Firehose-accepted source event copied to S3 raw backup; the publisher must report zero failed puts | Structural and delivery verification |
| RTO | Operator target under 60 minutes after diagnosis | Runbook target only; not load-tested |
| Data loss | Zero intentional drops in the designed path | Invalid data is quarantined, not accepted as curated |
| Observability | Health represented by four metric alarms and one composite alarm | CloudWatch state verification |

The project must not describe the 60-minute target as a measured RTO until a timed recovery exercise has been captured.

## Security inheritance

The Firehose Direct PUT transport buffer uses its AWS-owned key. Durable raw, curated, error, artifact, log, and evidence data remains protected with the Phase 5 customer-managed KMS key. The phase creates a separate rotating key for SNS so its policy can explicitly authorize the CloudWatch alarm service without mutating the verified Phase 5 key. CloudFormation roles are limited to the delivery stream, transform function, log group, and `streaming/*` S3 prefixes. The transformer logs aggregate counts only.
