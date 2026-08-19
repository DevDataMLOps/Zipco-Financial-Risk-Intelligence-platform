# Phase 5 Evidence Catalog

## Current evidence state

The phase reached `DEPLOYED_RUN_AND_VERIFIED` with 24/24 controls passed. The repository contains the supplied terminal screenshot and a transparent transcription of the successful output. The authoritative machine-generated JSON remains at the recorded S3 URI.

## Required artifacts after deployment

| Artifact | Source | Portfolio purpose |
|---|---|---|
| [`aws_security_governance_verification.json`](aws_security_governance_verification.json) | Transcribed from supplied CloudShell output | Local control summary and run provenance with explicit source boundary |
| [`01-security-deployment-verified.png`](../screenshots/01-security-deployment-verified.png) | Final CloudShell output | Shows `DEPLOYED_RUN_AND_VERIFIED`, 24/24 controls, and the S3 evidence URI |
| `02-kms-cloudtrail-verified.png` *(optional)* | KMS key and CloudTrail console | Additional visual proof of rotation, logging, encryption, and validation |
| `03-config-access-analyzer-verified.png` *(optional)* | AWS Config and IAM Access Analyzer consoles | Additional visual proof of compliance and external-access analysis |
| `04-security-dashboard.png` *(optional)* | CloudWatch dashboard | Additional visual proof of operational detection |

## Evidence acceptance criteria

- Account identifiers may remain as infrastructure metadata.
- Access keys, session tokens, email addresses, browser cookies, and unrelated account details must be redacted.
- A screenshot is supporting evidence, not the machine source of truth.
- The downloaded JSON must match the S3 object from the printed run-specific URI.
- Config `NON_COMPLIANT` findings must remain visible and be described; they must not be edited to imply full account compliance.
