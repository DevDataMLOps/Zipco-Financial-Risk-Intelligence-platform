# Security Policy

## Data and credentials

- Do not commit AWS access keys, secret keys, session tokens, passwords, private customer data, or local `.env` files.
- Use temporary AWS credentials, named profiles, IAM roles, or CloudShell-managed sessions.
- Treat the repository's AWS account ID and resource names as non-secret infrastructure metadata.
- Keep large source and generated datasets in governed S3 prefixes, not Git.

## Reporting

If you find an exposed secret, revoke or rotate it immediately before removing it from Git history. Do not open a public issue containing the credential.

## Model-use warning

The risk engine is a synthetic analyst-prioritization demonstration. Do not use it for real fraud, AML, credit, eligibility, underwriting, or adverse-action decisions.

