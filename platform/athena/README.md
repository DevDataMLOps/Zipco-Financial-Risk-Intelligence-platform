# ZIPCO Athena Analytics and Query Validation

## Target

- AWS account: `825999268272`
- Region: `us-east-2` (Ohio)
- S3 bucket: `zipco-financial-platform-825999268272-us-east-2`
- Physical-table database: `zipco_financial_risk`
- Analytics-view database: `zipco_financial_analytics`
- Athena workgroup: `zipco-risk-analytics`

## What the implementation creates

- An Athena engine version 3 workgroup with enforced S3 output settings.
- SSE-S3 encryption for query results.
- CloudWatch workgroup metrics.
- A 500 MiB per-query scan limit.
- Four reusable analytics views in a separate analytics database.
- Four saved portfolio and risk queries in the Athena query editor.
- Eight automated query-validation rules.
- Versioned SQL assets and deployment evidence in S3.

The physical Glue database remains limited to the six verified relational tables. Athena views are kept in `zipco_financial_analytics` so they do not alter the Glue table contract.

The account risk bands are transparent portfolio-monitoring heuristics for this engineering demonstration. They must not be interpreted as fraud findings or credit decisions.

## Validation coverage

1. Exact row counts for all six tables.
2. Primary, alternate, and unique-key integrity.
3. All four foreign-key relationships.
4. One category per transaction and transaction coverage for every account.
5. Required values, domains, formats, and numeric ranges.
6. Transaction-type/category compatibility.
7. Date ranges and year-partition integrity.
8. Reconciliation of all four analytics views to the physical tables.

## CloudShell deployment

Upload `zipco_athena_implementation_bundle.zip` to the same Ohio CloudShell session, then run:

```bash
unzip -o zipco_athena_implementation_bundle.zip
chmod +x zipco-athena-implementation/deploy_and_run_zipco_athena.sh
./zipco-athena-implementation/deploy_and_run_zipco_athena.sh
```

The script deploys the workgroup and catalog resources, creates the views, runs all eight validations, executes four analytics queries, verifies the saved queries, and uploads a detailed evidence record to S3.

The expected completion message is:

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Views: 4/4
Validation status: PASS (8/8)
Analytics queries: PASS (4/4)
Saved queries: 4/4
```

Athena charges are based on data scanned. The curated Parquet format and enforced scan limit keep this validation run bounded, but the run is not free.
