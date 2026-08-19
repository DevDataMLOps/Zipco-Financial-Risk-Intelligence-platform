# IAM and Access Model

The deployable [IAM and Lake Formation demo](lake-formation-demo/README.md) exercises this persona model with LF-TBAC grants and positive/negative Athena access probes on an isolated catalog.

## Persona separation

| Persona | Can | Cannot |
|---|---|---|
| Data engineer | Run the named Glue job/crawler, manage ZIPCO partitions/tables, read/write governed pipeline prefixes, execute Athena in the governed workgroup | Administer IAM, CloudTrail, Config, or unrelated buckets |
| Risk analyst | Read curated and risk-engine assets, query with the governed workgroup, write query results | Read raw/quarantine data, mutate curated datasets, administer infrastructure |
| Data steward | Read quality/quarantine metadata, maintain contracts and Glue database classification tags, inspect Lake Formation tags | Run pipeline workloads, query raw financial records broadly, administer audit controls |
| Security auditor | Read CloudTrail, Config, Access Analyzer, CloudWatch, KMS metadata, audit objects, and bucket controls | Mutate platform data, run Glue jobs, change queries, update security resources |

All four role trust policies require `aws:MultiFactorAuthPresent=true`. Trusting the account root principal does not automatically grant every identity permission to assume a role: a caller still needs an identity policy allowing `sts:AssumeRole` on the specific role.

## Service identities

- Glue ETL role: retained from Phase 2 and extended only with use of the ZIPCO KMS key.
- CloudTrail-to-Logs role: writes only to the named audit log group.
- AWS Config recorder role: AWS managed read permissions plus delivery to the audit bucket and approved KMS key.
- Glue catalog-encryption role: performs catalog KMS operations on behalf of Glue.

## Root-account transition

Earlier portfolio deployment evidence shows root credentials were used in CloudShell. Phase 5 treats that as a bootstrap exception, not an operating model.

After deployment:

1. Confirm root MFA and remove any root access keys.
2. Create or federate a named administrative identity.
3. Grant that identity permission to assume only the required ZIPCO role.
4. Use the data engineer role for pipeline operations and the security auditor role for evidence review.
5. Investigate every `zipco-root-account-usage` alarm.

No credentials, access keys, passwords, or session tokens belong in this repository or S3 evidence.
