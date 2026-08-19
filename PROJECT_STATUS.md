# Project Status and Evidence Boundary

## Current status

| Phase | AWS implementation | Portfolio proof |
|---|---|---|
| Dataset analysis, architecture, and S3 | Complete and verified | Complete |
| Glue ETL and data quality | Complete and verified | Complete |
| Athena, Parquet, partitions, and optimization | Complete and verified | Complete |
| Financial analytics and explainable risk engine | Complete and verified | Complete |
| Security and governance | Complete and verified, including the isolated IAM/Lake Formation demo | Complete; optional console-detail screenshots remain |

## AWS environment used

- Region: Ohio (`us-east-2`)
- S3 bucket: `zipco-financial-platform-825999268272-us-east-2`
- Glue database: `zipco_financial_risk`
- Athena analytics database: `zipco_financial_analytics`
- Risk database: `zipco_financial_risk_engine`
- Athena workgroup: `zipco-risk-analytics`

The AWS account identifier and resource names are portfolio metadata, not credentials. No access keys, secret keys, passwords, or session tokens are committed.

## Evidence provenance

Machine-readable local profiling and quality artifacts are included. AWS completion values are retained in explicitly labeled verification JSON files transcribed from the supplied CloudShell output. Their authoritative machine-generated records remain in the S3 evidence prefixes documented by each phase.

This distinction prevents the repository from presenting a transcription as though it were a downloaded AWS execution record.

## Data boundary

Large generated CSV tables, the original one-million-row source, the supplied PDF, build ZIPs, and temporary files are intentionally excluded from Git. The deterministic generator, contracts, quality summaries, SQL, infrastructure, documentation, and evidence needed to understand and reproduce the project are included.

## Known scope limits

- QuickSight is not deployed; BI proof uses Athena semantic views, saved queries, and a portfolio dashboard presentation.
- The risk engine is deterministic and synthetic; it is not a validated production model.
- The optimization benchmark covers four query strategies with three uncached runs each; it is not a concurrency or stress test.
- Phase 5 changes default S3 encryption for new writes; it does not re-encrypt historical object versions. A separately approved migration is required for that operation.
- Lake Formation enforcement is intentionally not activated on the three existing analytics databases. The verified isolated hybrid-access demo under `zipco_lf_governance_demo` proves LF-TBAC through observed allow/deny Athena probes without interrupting the existing Glue and Athena workloads.
- Security alarms have no external notification destination until an approved operational channel is supplied.
- AWS Config evaluates both ZIPCO resources and account-level identity posture; noncompliant findings remain visible and are not treated as a deployment failure unless they violate a mandatory structural gate.
