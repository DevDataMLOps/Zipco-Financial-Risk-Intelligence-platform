# CloudShell Deployment Runbook

## Prerequisites

- Region is `us-east-2`.
- Phases 1–5 are deployed.
- The primary ZIPCO bucket and KMS alias `alias/zipco-financial-platform` exist.
- The caller can deploy CloudFormation with named IAM resources and use Firehose, Lambda, CloudWatch, SNS, S3, IAM, and KMS.
- CloudShell provides `aws`, `python3`, `zip`, and `jq`.

## Upload and run

Upload the Phase 6 bundle to CloudShell, then execute:

```bash
unzip -o zipco_streaming_resilience_bundle.zip
chmod +x zipco-streaming-resilience/deploy_and_verify_zipco_streaming_resilience.sh
./zipco-streaming-resilience/deploy_and_verify_zipco_streaming_resilience.sh
```

Firehose buffering makes delivery asynchronous. The verifier waits for raw, curated, and error objects for up to 12 minutes.

The Firehose transport buffer intentionally uses an AWS-owned key. The ZIPCO customer-managed key still protects every durable S3 delivery, the Lambda and Firehose log groups, artifacts, and evidence. Direct PUT removes the account-specific Kinesis resource that repeatedly returned an AWS service `InternalFailure`.

## Optional alert email

```bash
ALERT_EMAIL=approved-operations-address@example.com \
  ./zipco-streaming-resilience/deploy_and_verify_zipco_streaming_resilience.sh
```

AWS sends a confirmation message. The subscription does not deliver alarms until the recipient confirms it. Do not use an address without permission.

## Expected completion

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Streaming controls: PASS (20/20)
Firehose stream: zipco-streaming-transactions-dev (Direct PUT, encrypted transport buffer)
Valid records curated: 25/25
Expected-invalid records: 3 sent to the Firehose error path
Recovery: raw backup enabled; replay dry run passed
CloudWatch: 4 metric alarms + 1 composite alarm
Dashboard: https://us-east-2.console.aws.amazon.com/cloudwatch/...
Evidence: s3://.../streaming/evidence/run_id=.../zipco_streaming_resilience_deployment_verification.json
```

## If deployment fails

Inspect the failing resource without deleting recovery data:

```bash
aws cloudformation describe-stack-events \
  --stack-name zipco-streaming-resilience \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
  --output table \
  --no-cli-pager
```

If verification times out, inspect:

```bash
aws firehose describe-delivery-stream \
  --delivery-stream-name zipco-streaming-transactions-dev \
  --no-cli-pager

aws logs tail /aws/firehose/zipco-streaming-dev --since 30m
aws logs tail /aws/lambda/zipco-stream-transform-dev --since 30m
```

Do not repeatedly republish test records while Firehose is still draining. At-least-once replay can create duplicates.

## Cleanup

After capturing evidence, the CloudFormation stack can be deleted if the streaming demo is no longer needed:

```bash
aws cloudformation delete-stack --stack-name zipco-streaming-resilience
aws cloudformation wait stack-delete-complete --stack-name zipco-streaming-resilience
```

CloudFormation intentionally retains the dedicated alert KMS key and the two log groups. S3 artifacts, streaming data, errors, raw backups, and evidence also remain. Review retention requirements and costs before separately removing any material evidence.
