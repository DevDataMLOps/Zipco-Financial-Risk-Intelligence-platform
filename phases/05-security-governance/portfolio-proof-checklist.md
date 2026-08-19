# Security and Governance Portfolio-Proof Checklist

## Before AWS deployment

- [x] Security architecture and trust boundaries documented
- [x] Customer-managed KMS and audit infrastructure defined as code
- [x] Four MFA-gated personas defined with separated duties
- [x] CloudTrail, Config, Access Analyzer, inventory, detection, and dashboard automation implemented
- [x] Classification catalog and responsible-use boundaries versioned
- [x] Verification script fails closed on mandatory controls
- [x] Existing-object encryption and service-cost limitations disclosed
- [x] CloudFormation templates validated by the AWS service

## Required AWS proof

- [x] Security stack reaches `CREATE_COMPLETE` or `UPDATE_COMPLETE`
- [x] KMS key is enabled and rotation is on
- [x] Data and audit buckets show SSE-KMS plus S3 Bucket Keys
- [x] CloudTrail is logging, multi-region, encrypted, and validation-enabled
- [x] Glue security configuration shows KMS for S3/logs/bookmarks
- [x] Athena workgroup shows enforced `SSE_KMS`
- [x] Catalog encryption uses the catalog service role
- [x] Four personas and IAM Access Analyzer are verified
- [x] AWS Config recorder is active and 15 rules exist
- [x] Weekly inventory includes encryption status
- [x] Glue databases carry verified governance tags and all tables reconcile to the versioned classification catalog
- [x] Three alarms and the security dashboard exist
- [x] Script ends with `DEPLOYED_RUN_AND_VERIFIED`
- [x] Run-specific evidence JSON is retained in S3 and a source-labeled transcription is added under `evidence/`
- [x] Final CloudShell verification screenshot is added under `screenshots/`
- [ ] Optional KMS/CloudTrail, Config/Access Analyzer, and dashboard console screenshots are added

## IAM/Lake Formation extension

- [x] Isolated hybrid-access implementation, LF-tags, persona grants, and automated allow/deny probes are versioned
- [x] The extension completes its AWS run with `18/18`, `SUCCEEDED`, and `FAILED_AS_EXPECTED`
- [x] Its run-specific evidence JSON is retained in S3 and the final CloudShell screenshot is retained locally

See the dedicated [IAM/Lake Formation checklist](lake-formation-demo/portfolio-proof-checklist.md).

## Claim boundary

Before every required AWS proof item is captured, say:

> Implemented a deployable AWS security and governance control plane with automated verification.

After successful deployment and evidence capture, say:

> Deployed and verified a KMS-backed AWS governance plane with multi-region audit logging, least-privilege personas, continuous configuration checks, object inventory, access analysis, and machine-readable evidence.
