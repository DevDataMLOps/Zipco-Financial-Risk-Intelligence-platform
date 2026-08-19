# IAM and Lake Formation Demo Evidence Catalog

## Current state

The AWS run reached `DEPLOYED_RUN_AND_VERIFIED` with 18/18 controls passed. The final CloudShell screenshot and a source-labeled transcription are retained locally; the authoritative machine-generated JSON remains at the recorded S3 URI.

## Required evidence

| Artifact | Source | Acceptance criterion |
|---|---|---|
| `zipco_iam_lake_formation_demo_verification.json` | Run-specific S3 evidence object | Verified at `run_id=20260819T193430Z-lambda`; `status=DEPLOYED_RUN_AND_VERIFIED`, `controls=18/18`, authorized query succeeds, denied query fails |
| [`01-lake-formation-demo-verified.png`](../screenshots/01-lake-formation-demo-verified.png) | Final CloudShell output | Shows `18/18`, both query outcomes, `12/12` opt-ins, unchanged catalog, and evidence URI |
| [`aws_lake_formation_demo_verification_transcript.json`](aws_lake_formation_demo_verification_transcript.json) | Source-labeled transcription | Preserves the visible result and evidence URI without representing itself as the Lambda-generated JSON |
| `02-lf-tags-and-permissions.png` *(optional)* | Lake Formation → Permissions | Shows persona LF-TBAC grants for the two ZIPCO LF-tags |
| `03-hybrid-access-opt-ins.png` *(optional)* | Lake Formation → Hybrid access mode | Shows the demo database/table opt-ins only |
| `04-registered-location.png` *(optional)* | Lake Formation → Data lake locations | Shows `governance-demo` registered in hybrid mode with the custom role |

## Machine-evidence fields

The JSON evidence records:

- original caller and scoped deployment role ARNs;
- database, table, registered S3 location, custom data-access role, KMS key, and Athena workgroup;
- observed database/table LF-tags;
- persona count, opt-in count, and auditor `SELECT=false` assertion;
- both Athena query execution IDs, terminal states, and denial reason;
- before/after table counts for the three existing analytics databases;
- contract and fixture SHA-256 hashes;
- run-specific S3 URI and Lake Formation console URL.

## Redaction and interpretation

- Never retain access keys, secret keys, session tokens, cookies, or unrelated account details.
- IAM role and AWS resource ARNs are acceptable infrastructure evidence.
- The denied query is an expected passing result for the negative control.
- The four-row fixture is not financial-analysis evidence and must not be presented as a production dataset.
