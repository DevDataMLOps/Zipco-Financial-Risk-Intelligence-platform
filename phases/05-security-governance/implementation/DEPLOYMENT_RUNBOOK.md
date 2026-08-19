# Phase 5 CloudShell Deployment Runbook

## Prerequisites

- Region is **US East (Ohio), `us-east-2`**.
- The verified ZIPCO S3, Glue, Athena, monitoring, and risk-engine phases still exist.
- CloudShell can run `aws`, `jq`, and `sha256sum`.
- The caller can create KMS keys, IAM roles, CloudTrail, Config rules, Access Analyzer, S3 controls, CloudWatch resources, and CloudFormation stacks.
- Review the cost notice below before continuing.

## Cost notice

This phase can incur charges for a customer-managed KMS key and requests, AWS Config recording and rule evaluations, CloudTrail data events, CloudWatch log ingestion/retention, S3 Inventory, and audit storage. The default enables S3 object data events for the strongest portfolio proof.

## Deploy

Upload `zipco_security_governance_bundle.zip` to CloudShell, then run:

```bash
unzip -o zipco_security_governance_bundle.zip
chmod +x zipco-security-governance/deploy_and_verify_zipco_security_governance.sh
./zipco-security-governance/deploy_and_verify_zipco_security_governance.sh
```

For the lower-cost exception that disables chargeable S3 object data events:

```bash
ENABLE_S3_DATA_EVENTS=false ./zipco-security-governance/deploy_and_verify_zipco_security_governance.sh
```

Do not close CloudShell while the stack updates are running. The script can be rerun safely after a connection loss.

## Expected completion

The final lines must include:

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Security controls: PASS (.../...)
IAM personas: 4/4
AWS Config rules: 15/15
```

The Config posture line may report `NON_COMPLIANT` or `INSUFFICIENT_DATA`. Those are transparent account-level findings and initial evaluation states, not reasons to rewrite the evidence.

## Retrieve evidence

The script writes a local file:

```text
zipco-security-governance/zipco_security_governance_deployment_verification.json
```

It also uploads a run-specific copy and a latest pointer beneath:

```text
s3://zipco-financial-platform-825999268272-us-east-2/security-governance/evidence/
s3://zipco-financial-platform-825999268272-us-east-2/metadata/contracts/security-governance/
```

Download the local JSON and retain the terminal output and redacted console screenshots listed in the evidence catalog.

## Recovery

- If the security stack ends in `ROLLBACK_COMPLETE`, rerun the script; it deletes only the exact failed `zipco-security-governance` stack before retrying.
- If Access Analyzer already exists, the script reuses the active account analyzer.
- If AWS Config already has a recorder or delivery channel, the script preserves it and adds the ZIPCO rules.
- If a mandatory verification fails, inspect the named control before retrying. Do not bypass the gate by editing evidence.
- KMS keys and the audit bucket use retain policies. Deleting the CloudFormation stack does not erase retained evidence or immediately delete the key.

## Post-deployment security tasks

1. Enable and verify root MFA; remove root access keys.
2. Stop using root for normal operations.
3. Connect an approved notification destination to the three security alarms.
4. Review Access Analyzer and Config findings.
5. Decide whether existing SSE-S3 object versions require an approved KMS migration.
6. For real data, complete privacy/legal review and enable sensitive-data discovery such as Amazon Macie.
