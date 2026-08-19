# Security and Governance Implementation

## Files

| File | Purpose |
|---|---|
| `zipco_security_governance_infrastructure.json` | KMS, audit bucket, CloudTrail, IAM roles, Config/catalog roles, Access Analyzer, alarms, and dashboard |
| `zipco_security_config_rules.json` | Fifteen AWS Config managed rules |
| `security_governance_contract.json` | Control IDs, mandatory gates, evidence schema, and explicit boundaries |
| `deploy_and_verify_zipco_security_governance.sh` | Idempotent deployment, integration upgrades, verification, and evidence generation |
| `DEPLOYMENT_RUNBOOK.md` | CloudShell deployment and recovery procedure |

The release ZIP also contains `data_classification_catalog.json` and a `dependencies/` directory holding the exact patched Glue, Athena, and observability templates needed to upgrade the existing stacks.

## Verification behavior

The script reads AWS state after deployment. Mandatory discrepancies terminate the run. AWS Config compliance values are recorded but do not cause a false infrastructure failure because account-level identity findings may require separate remediation.

The script does not copy existing S3 objects over themselves. Consequently, it proves the default protection for new writes, while S3 Inventory exposes the encryption status of existing versions for a later approved migration.
