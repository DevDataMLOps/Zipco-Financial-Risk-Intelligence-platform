# IAM and Lake Formation Portfolio-Proof Checklist

## Implementation proof

- [x] Isolated S3 prefix and Glue catalog designed
- [x] Hybrid Lake Formation registration defined as code
- [x] Customer-managed KMS path retained
- [x] Two LF-tags and catalog associations defined
- [x] Four existing IAM personas mapped to separated LF-TBAC permissions
- [x] Data steward can associate classification tags without reading table rows
- [x] Security auditor is metadata-only and has no `SELECT`
- [x] Positive and negative Athena access probes implemented
- [x] Existing-database before/after regression guard implemented
- [x] Versioned JSON evidence and SHA-256 integrity fields implemented
- [x] CloudShell rerun/recovery path documented

## Required AWS proof

- [x] Bootstrap stack reaches `CREATE_COMPLETE` or `UPDATE_COMPLETE`
- [x] Demo stack reaches `CREATE_COMPLETE` or `UPDATE_COMPLETE`
- [x] Registered location shows hybrid access enabled and the custom data-access role
- [x] Database and table show the expected LF-tags
- [x] Four persona LF-TBAC mappings are visible
- [x] Twelve principal-resource opt-ins are present
- [x] Authorized probe query reaches `SUCCEEDED`
- [x] Metadata-only probe query reaches `FAILED`
- [x] Existing analytics catalog reports `UNCHANGED (3/3 databases)`
- [x] Script ends with `DEPLOYED_RUN_AND_VERIFIED` and `18/18`
- [x] Run-specific JSON is retained at the printed S3 evidence URI
- [ ] Optional local download of the machine-generated JSON is retained
- [x] Final CloudShell screenshot is retained under `screenshots/`
- [ ] Optional Lake Formation permissions and hybrid-access console screenshots are retained

## Claim boundary

Implementation-only claim, used before the successful AWS run:

> Implemented an isolated IAM and Lake Formation access-control demonstration with automated validation.

Verified claim, now supported by the final AWS output:

> Deployed and verified Lake Formation tag-based access control with an observed authorized query, an observed denied query, and no changes to the existing analytics databases.
