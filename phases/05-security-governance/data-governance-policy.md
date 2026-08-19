# Data Governance Policy

## Scope and ownership

The governed asset is ZIPCO Relational Dataset v2 and its derived Glue, Athena, benchmark, and risk-engine products. `RiskAnalytics` is the documented data owner; the data steward maintains contracts, classification, lineage, quality rules, and approved retention.

## Classification

| Class | Examples | Handling |
|---|---|---|
| Restricted-PII | Name, email, phone | Need-to-know access; never a risk-model feature; never included in public evidence |
| Confidential-Financial | Account, balance, transaction, amount, date, relationship keys | KMS-encrypted, role-scoped, audited, aggregated before portfolio publication |
| Internal-Reference | Category definitions, synthetic market reference values, surrogate IDs | Governed internal analytics; publish only when context cannot identify a person |
| Public-Portfolio | Architecture, code, contracts, aggregated metrics, redacted screenshots | May be stored in GitHub after secret and privacy review |

The machine-readable source of truth is [data_classification_catalog.json](contracts/data_classification_catalog.json). Glue resource tags identify database-level ownership and classification; table and column coverage is maintained in this versioned catalog because Glue tables do not support Glue resource tags.

## Lifecycle

- Raw data remains immutable and versioned; lifecycle transitions preserve lineage.
- Validated and curated data is regenerated from versioned inputs and contracts.
- Quarantine records expire after the approved diagnostic period.
- Athena results use short retention because they may contain row-level extracts.
- Audit records are separated from platform data and retained according to the deployment parameter.
- Deletion or re-encryption of existing versions requires an approved change record and recovery plan.

## Quality and lineage

Security does not replace data quality. Publication still requires the Phase 2 quality gates, primary/foreign-key rules, domain checks, and reconciliation. Every security deployment emits a run ID, caller ARN, observed AWS configuration, control outcomes, and immutable S3 evidence location.

## Model governance

PII columns are prohibited as risk features. The model remains deterministic, synthetic, and suitable only for analyst prioritization. No score is a probability, finding, disposition, eligibility judgment, or adverse-action reason. Human review, legal/privacy assessment, fairness evaluation, independent validation, change approval, monitoring, and rollback are mandatory before any real-data use.

## Exceptions

An exception must record the control, owner, reason, risk, compensating control, approval, expiration date, and remediation plan. Cost is not a silent exception: disabling CloudTrail S3 data events is recorded by the script and visible through AWS Config.
