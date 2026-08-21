# Phase 6 Evidence Catalog

## Verified selected variant

The Free-plan Lambda/S3 operational demo completed in `us-east-2` with `DEPLOYED_RUN_AND_VERIFIED` and `PASS (20/20)`. Native Kinesis and Firehose services are not claimed.

| Evidence | Verified observation |
|---|---|
| Final CloudShell output | Selected variant identified; native streaming denied; `PASS (20/20)` |
| Delivery outcome | 25/25 expected-valid records curated; 3/3 expected-invalid records quarantined |
| Recovery outcome | Encrypted raw backup enabled; bounded replay dry run passed |
| Monitoring | Four metric alarms and one composite alarm |
| Processor | `zipco-free-plan-event-processor-dev` |
| Run lineage | `20260821T215343Z-cloudshell` |
| Machine evidence | Run-specific verifier JSON stored in S3 |

## Repository evidence

- [`aws_free_plan_event_resilience_verification_transcript.json`](aws_free_plan_event_resilience_verification_transcript.json) records the values visible in the user-supplied screenshot and labels them as a transcription.
- [`../screenshots/01-free-plan-event-resilience-verified.png`](../screenshots/01-free-plan-event-resilience-verified.png) is the retained source screenshot.
- [`../operational-demo.md`](../operational-demo.md) maps the AWS outcome to an interview-ready operational walkthrough.
- [`../dashboard/README.md`](../dashboard/README.md) presents a GitHub-native dashboard whose values are constrained to this catalog's verified evidence.
- [`../free-plan-implementation/free_plan_event_resilience_contract.json`](../free-plan-implementation/free_plan_event_resilience_contract.json) defines the 20 mandatory controls and the non-streaming claim boundary.

## Authoritative AWS record

```text
s3://zipco-financial-platform-825999268272-us-east-2/streaming-free-plan/evidence/run_id=20260821T215343Z-cloudshell/zipco_free_plan_event_resilience_verification.json
```

The authoritative machine-generated JSON remains in S3. The checked-in transcript is not represented as a downloaded verifier export.

## Optional managed-streaming evidence boundary

The Firehose Direct PUT design remains under `implementation/`, but AWS rejected Firehose with `OptInRequired` on the selected Free plan. Its templates and tests are architecture proof only and must not be cited as deployed infrastructure.
