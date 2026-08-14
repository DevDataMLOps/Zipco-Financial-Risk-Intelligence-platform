# Secure S3 Foundation

This directory contains the deployment automation for the ZIPCO S3 data-lake baseline and the verified controls contract.

- `deploy_zipco_s3.py` creates and verifies the governed bucket structure.
- `zipco_s3_controls.json` documents the deployed security, versioning, lifecycle, and prefix controls.

The deployment target was `zipco-financial-platform-825999268272-us-east-2` in Ohio (`us-east-2`). Review names, retention rules, and costs before reuse in another AWS account.
