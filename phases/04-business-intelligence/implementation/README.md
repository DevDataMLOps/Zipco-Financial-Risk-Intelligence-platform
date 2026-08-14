# Reproducible Risk-Engine Implementation

This directory preserves the deployable implementation behind the BI case study:

- `views/`: six Athena semantic views for features, entity scores, KPIs, and monthly trends.
- `analytics/`: six portfolio and review-queue query products.
- `validation/`: ten automated publication-gate rules.
- `risk_model_contract.json`: original pre-execution model and governance contract.
- `deploy_and_run_zipco_risk_engine.sh`: AWS deployment, validation, saved-query, and evidence automation.

The original contract's `READY_FOR_AWS_EXECUTION` status is intentionally preserved as a pre-run artifact. The later AWS result appears in `../contracts/zipco_verified_risk_engine.json` and `../evidence/aws_risk_engine_verification.json`.

