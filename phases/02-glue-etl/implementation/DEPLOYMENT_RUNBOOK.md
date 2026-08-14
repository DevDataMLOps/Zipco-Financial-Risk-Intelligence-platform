# ZIPCO Glue Validation and Transformation Runbook

## Target

- AWS account: `825999268272`
- Region: `us-east-2` (Ohio)
- Bucket: `zipco-financial-platform-825999268272-us-east-2`
- Source: `validated/relational_v2/`
- Curated output: `curated/relational_v2/`

## Implementation

The bundle creates and runs:

- An encrypted AWS Glue 5.1 Spark job using two autoscaling G.1X workers.
- A least-privilege Glue service role scoped to the ZIPCO data-lake prefixes.
- A Glue security configuration using S3-managed encryption.
- A `zipco_financial_risk` Data Catalog database.
- A curated Parquet crawler for the six v2 tables.

The ETL job performs:

- Exact header/schema enforcement before processing.
- Source-manifest verification for SHA-256 metadata, bytes, declared rows, dataset version, and S3 encryption before Glue starts.
- Typed conversion to long, date/timestamp, and `DECIMAL(18,2)` fields.
- Required-value, email, phone, transaction-domain, category-compatibility, and numeric checks.
- Primary-key, alternate-key, and composite-key uniqueness checks.
- Customer-account, account-transaction, transaction-category, and category-reference validation.
- Structured quarantine records with original input, error codes, source file, run ID, and processing timestamp.
- Per-table and overall quality metrics written under `quality/relational_v2/`.
- Locked row-count checks against the v2 generation manifest, with publication blocked on any mismatch.
- Curated Snappy Parquet output.
- `transactions` partitioned by `TransactionYear`; `market_data` partitioned by `MarketYear`.

Curated publication is blocked when the overall rejected-record rate exceeds 1%, any valid transaction lacks a category, or any valid account lacks a transaction. The expected v2 run has zero rejected records.

## CloudShell deployment

Upload `zipco_glue_implementation_bundle.zip` to the working Ohio CloudShell session, then run:

```bash
unzip -o zipco_glue_implementation_bundle.zip
chmod +x zipco-glue-implementation/deploy_and_run_zipco_glue.sh
./zipco-glue-implementation/deploy_and_run_zipco_glue.sh
```

The script verifies the six source objects, deploys the CloudFormation stack, runs Glue, starts the crawler, verifies the six Parquet outputs and exact Data Catalog table set, and uploads the final verification record to S3.

The Glue job incurs AWS Glue processing charges while it runs. The configuration uses a small autoscaling two-worker ceiling appropriate for the current dataset.
