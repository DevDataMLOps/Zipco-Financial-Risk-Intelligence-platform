# Free-plan CloudShell Deployment

## Before deployment

- Keep the AWS account on the Free plan.
- Delete the failed `zipco-streaming-resilience` CloudFormation stack after retaining its error screenshot.
- Confirm Phases 1–5 and the KMS alias `alias/zipco-financial-platform` remain deployed.
- This variant uses Lambda, S3, CloudWatch, SNS, IAM, and KMS resources already proven available in the account.

## Upload and run

Upload `zipco_free_plan_event_resilience_bundle.zip` to CloudShell, then run:

```bash
unzip -o zipco_free_plan_event_resilience_bundle.zip
chmod +x zipco-free-plan-event-resilience/deploy_and_verify_zipco_free_plan_event_resilience.sh
./zipco-free-plan-event-resilience/deploy_and_verify_zipco_free_plan_event_resilience.sh
```

Expected final output:

```text
Status: DEPLOYED_RUN_AND_VERIFIED
Deployment variant: FREE_PLAN_LAMBDA_EVENT_PROCESSING
Native streaming service: NOT CLAIMED
Event-resilience controls: PASS (20/20)
Valid records curated: 25/25
Expected-invalid records quarantined: 3/3
```

## Failure inspection

```bash
aws cloudformation describe-stack-events \
  --stack-name zipco-free-plan-event-resilience \
  --region us-east-2 \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]" \
  --output table \
  --no-cli-pager
```

Do not describe this fallback as a Kinesis or Firehose deployment. Its portfolio value is the raw-first recovery pattern, schema enforcement, error quarantine, replay safety, least-privilege permissions, CloudWatch monitoring, and automated evidence.
