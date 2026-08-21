# Operational Demo Portfolio-Proof Checklist

## Selected Free-plan implementation

- [x] Lambda event processor deployed with schema-v2.1.0 enforcement
- [x] Complete invocation batch persisted to encrypted raw S3 before validation outputs
- [x] Valid records normalized into GZIP NDJSON event-time partitions
- [x] Contract-invalid records isolated beneath the typed error prefix
- [x] Safe bounded replay utility defaults to dry run and requires explicit `--execute`
- [x] S3 writes restricted to `streaming-free-plan/*` without `s3:*`
- [x] Four metric alarms, one composite alarm, encrypted SNS topic, and dashboard deployed
- [x] Automated 20-control verifier and run-specific S3 evidence publication deployed

## AWS operational proof

- [x] CloudFormation deployment reported `DEPLOYED_RUN_AND_VERIFIED`
- [x] Selected variant reported `FREE_PLAN_LAMBDA_EVENT_PROCESSING`
- [x] Native streaming service explicitly reported `NOT CLAIMED`
- [x] Event-resilience controls reported `PASS (20/20)`
- [x] 25/25 expected-valid events observed in curated S3
- [x] Complete source batch preserved in encrypted raw S3
- [x] 3/3 expected-invalid events observed under the quarantine prefix
- [x] Recovery utility dry run passed with deterministic replay fingerprint
- [x] Four metric alarms and one composite alarm verified
- [x] Machine evidence JSON uploaded to the run-specific S3 prefix
- [x] Final CloudShell screenshot retained with SHA-256 provenance
- [x] Source-labelled verification transcript committed

## Portfolio presentation

- [x] Actual deployed architecture diagram included
- [x] Failure-injection and quarantine narrative included
- [x] Recovery and replay workflow explained
- [x] Five-minute interview walkthrough included
- [x] Evidence catalog and authoritative S3 URI included
- [x] Limitations and non-streaming claim boundary explicit
- [x] Resume-ready outcome bullets included
- [x] GitHub-native operational dashboard and standalone visual included
- [x] Integrity manifest updated

## Optional paid-plan reference

- [x] Firehose Direct PUT architecture and automation retained as reference material
- [x] Free-plan `OptInRequired` restriction documented
- [ ] Native Kinesis/Firehose deployment — intentionally not claimed or required for completion

**Phase status: COMPLETE — Free-plan event processing, recovery, CloudWatch monitoring, 20/20 AWS verification, and operational-demo portfolio proof. Native managed streaming is not claimed.**
