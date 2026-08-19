# IAM and Lake Formation Demo — CloudShell Runbook

## Before running

- Use **US East (Ohio), `us-east-2`**.
- Keep the verified S3, Glue, Athena, risk-engine, and security stacks deployed.
- Run from a caller that can create/pass IAM roles and CloudFormation stacks and can update Lake Formation data lake settings. The current root-backed CloudShell session is supported, although routine project operations should move to an administrative IAM role after this bootstrap.
- CloudShell must provide `aws`, `jq`, `sha256sum`, and `grep`.

The bootstrap appends a CloudFormation execution role and a Lambda validation role to the current Lake Formation administrator list. It does not replace current administrators or account-wide database/table defaults. Root does not assume either role.

## Deploy and validate

Upload `zipco_iam_lake_formation_demo_bundle.zip` to CloudShell, then run:

```bash
unzip -o zipco_iam_lake_formation_demo_bundle.zip
chmod +x zipco-iam-lake-formation-demo/deploy_and_verify_zipco_lake_formation_demo.sh
./zipco-iam-lake-formation-demo/deploy_and_verify_zipco_lake_formation_demo.sh
```

The script can be rerun safely after a CloudShell disconnect. It creates or updates only these exact stacks:

- `zipco-lake-formation-bootstrap`
- `zipco-lake-formation-demo`

## Expected completion

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Lake Formation controls: PASS (18/18)
Registered location: arn:aws:s3:::.../governance-demo (HYBRID)
LF-TBAC tags: zipco-domain=risk-analytics, zipco-sensitivity=internal
Persona mappings: 4/4
Hybrid opt-ins: 12/12
Authorized query: SUCCEEDED
Metadata-only query: FAILED_AS_EXPECTED
Existing analytics catalog: UNCHANGED (3/3 databases)
```

Do not treat the expected denied query as an error. It is the negative access-control test.

## Evidence to retain

The local machine-generated file is:

```text
zipco-iam-lake-formation-demo/zipco_iam_lake_formation_demo_verification.json
```

The script also prints a run-specific S3 URI beneath:

```text
s3://zipco-financial-platform-825999268272-us-east-2/security-governance/lake-formation-demo/evidence/
```

Download the JSON and capture the final CloudShell output. Then use the [evidence catalog](../evidence/evidence-catalog.md) to capture the optional console views.

## Recovery

- If either exact stack is `ROLLBACK_COMPLETE`, rerun the script; it removes only that failed stack before retrying.
- If the bootstrap cannot append the deployment role as a Lake Formation administrator, confirm the caller has `lakeformation:GetDataLakeSettings` and `lakeformation:PutDataLakeSettings`.
- If the authorized query fails, inspect the Athena state-change reason, registered-location role, KMS access, LF-tags, and opt-ins.
- If the denied query succeeds, stop: the metadata-only role has unexpected `SELECT` access and the validation correctly refuses to publish passing evidence.
- Do not grant Lake Formation permissions to the three existing analytics databases to make this demo pass; the isolated database is the only intended target.

## Cost note

This demo makes a small number of Lake Formation, Glue, Athena, KMS, S3, IAM, STS, and CloudFormation calls. The four-row fixture scans only a few bytes, but normal AWS service charges and retained resources can still apply.
