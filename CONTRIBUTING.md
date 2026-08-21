# Contributing

## Change workflow

1. Create or reuse a focused branch; do not commit directly to `main`.
2. Keep implementation, contracts, evidence, and documentation synchronized.
3. Preserve synthetic-data, responsible-use, and evidence-provenance boundaries.
4. Run the repository validator before committing:

   ```powershell
   python scripts/validate_repository.py
   ```

5. Review the exact files being staged. Do not commit credentials, local environments, large datasets, generated bundles, or temporary AWS output.
6. Open a draft pull request, wait for GitHub Actions, and complete the pull-request checklist.

## Evidence changes

- Label console-derived transcriptions as transcriptions and retain the source screenshot hash where supported.
- Never invent an AWS result or change an expected outcome to make validation pass.
- Store authoritative execution evidence in the documented versioned S3 `run_id` prefix.
- Update the relevant phase `MANIFEST.sha256` whenever a manifested phase artifact changes.

## Infrastructure changes

- Validate CloudFormation before deployment and review replacement behavior for named resources.
- Preserve encryption, public-access blocking, TLS-only access, least privilege, logging, and quarantine controls.
- Document chargeable services and cleanup implications.
- Test recovery in dry-run mode before executing replay or destructive remediation.

## Pull requests

Keep each pull request scoped and explain what is implemented, what was verified, and what is deliberately not claimed. A passing workflow is required before the owner marks a pull request ready for review.
