# ZIPCO Financial Analytics + Risk Engine

## Target

- AWS account: `825999268272`
- Region: `us-east-2` (Ohio)
- Existing bucket: `zipco-financial-platform-825999268272-us-east-2`
- Existing Athena workgroup: `zipco-risk-analytics`
- New risk database: `zipco_financial_risk_engine`
- Risk model: `ZIPCO Explainable Financial Activity Risk Engine v1.0.0`

No additional S3 bucket is created.

## What this phase implements

The deployment creates six reusable Athena views:

1. Transaction features.
2. Explainable transaction scores.
3. Account scores.
4. Customer scores.
5. Reconciled financial KPIs.
6. Monthly risk trends.

It also creates six saved Athena queries for executive KPIs, risk distributions, customer review, transaction alerts, monthly trends, and category profiles.

## Model behavior

Scores range from 0 through 100 and map to:

- `LOW`: 0–29
- `MEDIUM`: 30–49
- `HIGH`: 50–69
- `CRITICAL`: 70–100

Every score contains component columns and pipe-delimited reason codes. Customer names, email addresses, and phone numbers are not scoring features. Market data remains separate because the supplied dictionary defines no relationship between market observations and transactions.

This deterministic model prioritizes synthetic portfolio activity for analyst review. It is not a fraud finding, AML disposition, credit score, underwriting model, or adverse-action mechanism.

## Publication gate

The installer fails unless:

- Six views exist.
- All ten validation rules pass.
- All six analytics queries return data.
- All six saved risk queries exist.
- Transactions, accounts, customers, balances, and transaction totals reconcile.
- Scores, components, bands, reason codes, and model version reconcile.
- All four risk bands are populated at all three entity levels.

## CloudShell deployment

Upload `zipco_financial_risk_engine_bundle.zip` to the Ohio CloudShell session and run:

```bash
unzip -o zipco_financial_risk_engine_bundle.zip
chmod +x zipco-financial-risk-engine/deploy_and_run_zipco_risk_engine.sh
./zipco-financial-risk-engine/deploy_and_run_zipco_risk_engine.sh
```

Expected completion:

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Risk views: 6/6
Validation status: PASS (10/10)
Financial analytics queries: PASS (6/6)
Saved risk queries: 6/6
```

The final line reports the versioned S3 evidence path.

## Cost and performance

The phase reuses the existing encrypted S3 bucket and governed Athena workgroup. Athena charges can arise from the deployment queries. Views do not store another copy of the source dataset; query results and deployment evidence use the existing S3 lifecycle-managed prefixes.
