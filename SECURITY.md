# Security Policy

## Data and credentials

- Do not commit AWS access keys, secret keys, session tokens, passwords, private customer data, or local `.env` files.
- Use temporary AWS credentials, named profiles, IAM roles, or CloudShell-managed sessions.
- Treat the repository's AWS account ID and resource names as non-secret infrastructure metadata.
- Keep large source and generated datasets in governed S3 prefixes, not Git.

## AWS operating model

- Use the Phase 5 MFA-gated persona roles for routine work: data engineer, risk analyst, data steward, or security auditor.
- Treat root-user CloudShell access as a bootstrap exception. Remove root access keys, enable root MFA, and do not use root for normal operations.
- New data, analytics results, Glue artifacts, catalog metadata, and audit records use the ZIPCO customer-managed KMS key after Phase 5 deployment.
- Changing S3 default encryption does not re-encrypt existing object versions. Historical objects require a separately reviewed migration plan.
- Keep CloudTrail, AWS Config, IAM Access Analyzer, and security alarms enabled; investigate findings rather than deleting evidence.
- Do not attach an alarm notification target without confirming the destination and its data-handling approval.
- Treat `streaming/raw/` and `streaming/errors/` as governed internal financial data, even though this repository's demonstration events are synthetic.
- Keep streaming payloads out of CloudWatch logs; the Phase 6 transformer records aggregate batch counts only.
- Run streaming replay in dry-run mode first, record its batch fingerprint, obtain change approval, and use `--execute` only for a bounded recovery set.
- Expect at-least-once delivery and de-duplicate downstream products on `transaction_id` after any retry or replay.

## Reporting

If you find an exposed secret, revoke or rotate it immediately before removing it from Git history. Do not open a public issue containing the credential.

## Model-use warning

The risk engine is a synthetic analyst-prioritization demonstration. Do not use it for real fraud, AML, credit, eligibility, underwriting, or adverse-action decisions.

The detailed control design and deployment boundary are in [`phases/05-security-governance`](phases/05-security-governance/README.md).

Streaming failure isolation and replay controls are documented in [`phases/06-streaming-resilience`](phases/06-streaming-resilience/README.md).
