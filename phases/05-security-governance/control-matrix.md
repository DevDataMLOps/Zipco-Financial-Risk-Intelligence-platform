# Security and Governance Control Matrix

## Implementation status

`Implemented` means the code and verification logic exist in the repository. `Pending AWS proof` means the control must still be deployed and observed in AWS.

| ID | Control | AWS mechanism | Verification | Status |
|---|---|---|---|---|
| SG-ENC-01 | Customer-managed key | AWS KMS | Key enabled and customer managed | Implemented; pending AWS proof |
| SG-ENC-02 | Key rotation | AWS KMS | `KeyRotationEnabled=true` | Implemented; pending AWS proof |
| SG-ENC-03 | S3 encryption | Default SSE-KMS + Bucket Keys | Read both bucket encryption configurations | Implemented; pending AWS proof |
| SG-ENC-04 | Glue encryption | Glue security configuration | S3 `SSE-KMS`, logs `SSE-KMS`, bookmarks `CSE-KMS` | Implemented; pending AWS proof |
| SG-ENC-05 | Athena encryption | Workgroup enforcement | Results use the approved `SSE_KMS` key | Implemented; pending AWS proof |
| SG-ENC-06 | Catalog encryption | Glue catalog KMS service role | Catalog mode `SSE-KMS-WITH-SERVICE-ROLE` | Implemented; pending AWS proof |
| SG-IAM-01 | Data engineering access | IAM role | Service/resource/prefix scopes inspected | Implemented; pending AWS proof |
| SG-IAM-02 | Risk analyst access | IAM role | Curated read plus governed query only | Implemented; pending AWS proof |
| SG-IAM-03 | Stewardship access | IAM role | Metadata, classification, quality, and contracts | Implemented; pending AWS proof |
| SG-IAM-04 | Audit separation | IAM role | Read-only security/audit actions; no data mutation | Implemented; pending AWS proof |
| SG-IAM-05 | MFA | IAM trust policies | `aws:MultiFactorAuthPresent=true` | Implemented; pending AWS proof |
| SG-IAM-06 | External access | IAM Access Analyzer | Account analyzer status `ACTIVE` | Implemented; pending AWS proof |
| SG-AUD-01 | Management audit | Multi-region CloudTrail | Trail logging and global events enabled | Implemented; pending AWS proof |
| SG-AUD-02 | Audit integrity | CloudTrail digest files | Log-file validation enabled | Implemented; pending AWS proof |
| SG-AUD-03 | Audit isolation | Dedicated audit S3 bucket | Private, versioned, KMS encrypted, lifecycle managed | Implemented; pending AWS proof |
| SG-AUD-04 | Object activity | CloudTrail S3 data events | Selector contains primary bucket ARN | Implemented; cost switch |
| SG-AUD-05 | Threat signals | Logs metrics and CloudWatch alarms | Three filters and three alarms exist | Implemented; pending AWS proof |
| SG-AUD-06 | Security visibility | CloudWatch dashboard | Dashboard body returned by API | Implemented; pending AWS proof |
| SG-GOV-01 | Configuration history | AWS Config recorder | Recorder reports `recording=true` | Implemented; pending AWS proof |
| SG-GOV-02 | Continuous compliance | 15 AWS managed rules | Rule inventory and compliance snapshot | Implemented; pending AWS proof |
| SG-GOV-03 | Object inventory | S3 Inventory | Weekly schedule includes `EncryptionStatus` | Implemented; pending AWS proof |
| SG-GOV-04 | Ownership metadata | Glue database tags + classification catalog | Three databases tagged and all catalog tables reconciled to the versioned column catalog | Implemented; pending AWS proof |
| SG-GOV-05 | Data classification | Versioned catalog contract | PII, financial, reference, and public classes defined | Complete locally |
| SG-GOV-06 | Responsible use | Model governance policy | Human-review and prohibited-use statements retained | Complete locally |

## AWS Config rule pack

The 15 managed rules evaluate public S3 access, TLS, encryption, KMS use, versioning, CloudTrail availability, multi-region coverage, CloudWatch delivery, CloudTrail KMS encryption, log validation, S3 data events, KMS rotation, root access keys, and IAM-user MFA.

AWS Config reports platform controls and wider account posture. A `NON_COMPLIANT` identity result is a finding to remediate, not a value to conceal. The deployment can still be structurally verified while reporting such findings explicitly.
