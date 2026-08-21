"""Verify the deployed Free-plan event-processing controls and delivery proof."""

from __future__ import annotations

import argparse
import gzip
import io
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def add_control(controls: list[dict[str, Any]], control_id: str, description: str, passed: bool, observed: Any) -> None:
    controls.append({"id": control_id, "description": description, "status": "PASS" if passed else "FAIL", "observed": observed})


def recent_objects(s3: Any, bucket: str, prefix: str, not_before: datetime) -> list[dict[str, Any]]:
    objects: list[dict[str, Any]] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            if item["LastModified"].astimezone(timezone.utc) >= not_before:
                objects.append(item)
    return sorted(objects, key=lambda item: item["LastModified"])


def count_run_records(s3: Any, bucket: str, objects: list[dict[str, Any]], run_id: str) -> int:
    count = 0
    for item in objects[-100:]:
        body = s3.get_object(Bucket=bucket, Key=item["Key"])["Body"].read()
        try:
            body = gzip.GzipFile(fileobj=io.BytesIO(body)).read()
        except (gzip.BadGzipFile, EOFError):
            pass
        for line in body.splitlines():
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and payload.get("run_id") == run_id:
                count += 1
    return count


def stack_state(cloudformation: Any, stack_name: str) -> tuple[str, dict[str, str]]:
    stack = cloudformation.describe_stacks(StackName=stack_name)["Stacks"][0]
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack.get("Outputs", [])}
    return stack["StackStatus"], outputs


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else [value]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-name", default="zipco-free-plan-event-resilience")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--not-before", required=True)
    parser.add_argument("--expected-valid", type=int, default=25)
    parser.add_argument("--expected-invalid", type=int, default=3)
    parser.add_argument("--publisher-result", required=True)
    parser.add_argument("--replay-result", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    session = boto3.Session(region_name=args.region)
    cloudformation = session.client("cloudformation")
    lambda_client = session.client("lambda")
    cloudwatch = session.client("cloudwatch")
    logs = session.client("logs")
    sns = session.client("sns")
    kms = session.client("kms")
    iam = session.client("iam")
    s3 = session.client("s3")

    stack_status, outputs = stack_state(cloudformation, args.stack_name)
    function_name = outputs["ProcessorFunctionName"]
    role_name = outputs["ProcessorRoleName"]
    log_group_name = outputs["ProcessorLogGroupName"]
    dashboard_name = outputs["DashboardName"]
    topic_arn = outputs["AlertTopicArn"]
    function = lambda_client.get_function_configuration(FunctionName=function_name)
    variables = function.get("Environment", {}).get("Variables", {})
    data_key_arn = variables.get("KMS_KEY_ARN", "")
    data_key = kms.describe_key(KeyId=data_key_arn)["KeyMetadata"]

    publisher = json.loads(Path(args.publisher_result).read_text(encoding="utf-8"))
    replay = json.loads(Path(args.replay_result).read_text(encoding="utf-8"))
    not_before = parse_time(args.not_before)
    deadline = time.monotonic() + args.timeout_seconds
    raw: list[dict[str, Any]] = []
    curated: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    raw_count = curated_count = error_count = 0
    while time.monotonic() < deadline:
        raw = recent_objects(s3, args.bucket, "streaming-free-plan/raw/", not_before)
        curated = recent_objects(s3, args.bucket, "streaming-free-plan/curated/", not_before)
        errors = recent_objects(s3, args.bucket, "streaming-free-plan/errors/", not_before)
        raw_count = count_run_records(s3, args.bucket, raw, args.run_id)
        curated_count = count_run_records(s3, args.bucket, curated, args.run_id)
        error_count = count_run_records(s3, args.bucket, errors, args.run_id)
        if raw_count >= args.expected_valid + args.expected_invalid and curated_count >= args.expected_valid and error_count >= args.expected_invalid:
            break
        time.sleep(10)

    encryption: dict[str, Any] = {}
    for label, collection in (("raw", raw), ("curated", curated), ("errors", errors)):
        if collection:
            head = s3.head_object(Bucket=args.bucket, Key=collection[-1]["Key"])
            encryption[label] = {"algorithm": head.get("ServerSideEncryption"), "kms_key_id": head.get("SSEKMSKeyId")}

    resources = cloudformation.list_stack_resources(StackName=args.stack_name)["StackResourceSummaries"]
    metric_alarms = sorted(item["PhysicalResourceId"] for item in resources if item["ResourceType"] == "AWS::CloudWatch::Alarm")
    composite_alarms = sorted(item["PhysicalResourceId"] for item in resources if item["ResourceType"] == "AWS::CloudWatch::CompositeAlarm")
    cloudwatch.describe_alarms(AlarmNames=metric_alarms + composite_alarms)
    dashboard = cloudwatch.get_dashboard(DashboardName=dashboard_name)
    log_groups = logs.describe_log_groups(logGroupNamePrefix=log_group_name).get("logGroups", [])

    topic = sns.get_topic_attributes(TopicArn=topic_arn)["Attributes"]
    alert_key = kms.describe_key(KeyId=topic["KmsMasterKeyId"])["KeyMetadata"]
    alert_rotation = kms.get_key_rotation_status(KeyId=alert_key["KeyId"])

    inline_policies = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    policy_documents = [iam.get_role_policy(RoleName=role_name, PolicyName=name)["PolicyDocument"] for name in inline_policies]
    s3_statements = [
        statement
        for policy in policy_documents
        for statement in as_list(policy.get("Statement", []))
        if any(str(action).startswith("s3:") for action in as_list(statement.get("Action", [])))
    ]
    no_s3_wildcard_actions = all("s3:*" not in as_list(statement.get("Action", [])) for statement in s3_statements)
    object_writes_scoped = any(
        "s3:PutObject" in as_list(statement.get("Action", []))
        and any(str(resource).endswith("/streaming-free-plan/*") for resource in as_list(statement.get("Resource", [])))
        for statement in s3_statements
    )

    controls: list[dict[str, Any]] = []
    add_control(controls, "FP-001", "CloudFormation stack is deployed", stack_status in {"CREATE_COMPLETE", "UPDATE_COMPLETE"}, stack_status)
    add_control(controls, "FP-002", "Lambda event processor is active", function.get("State") == "Active", function.get("State"))
    add_control(controls, "FP-003", "Processor uses the governed Python 3.12 runtime", function.get("Runtime") == "python3.12", function.get("Runtime"))
    add_control(controls, "FP-004", "Processor timeout is bounded between 60 and 300 seconds", 60 <= int(function.get("Timeout", 0)) <= 300, function.get("Timeout"))
    add_control(controls, "FP-005", "Processor enforces schema version 2.1.0", variables.get("EXPECTED_SCHEMA_VERSION") == "2.1.0", variables.get("EXPECTED_SCHEMA_VERSION"))
    add_control(controls, "FP-006", "Durable event paths use the customer-managed data key", data_key.get("KeyManager") == "CUSTOMER", data_key.get("Arn"))
    add_control(controls, "FP-007", "Processor is isolated to the Free-plan S3 prefix", variables.get("PREFIX_ROOT") == "streaming-free-plan", variables.get("PREFIX_ROOT"))
    add_control(controls, "FP-008", "Raw backup contains the complete verification batch", raw_count >= args.expected_valid + args.expected_invalid, raw_count)
    add_control(controls, "FP-009", "Curated S3 contains all expected-valid records", curated_count >= args.expected_valid, curated_count)
    add_control(controls, "FP-010", "Error S3 contains all expected-invalid records", error_count >= args.expected_invalid, error_count)
    all_encrypted = len(encryption) == 3 and all(value.get("algorithm") == "aws:kms" for value in encryption.values())
    add_control(controls, "FP-011", "Observed raw, curated, and error objects use SSE-KMS", all_encrypted, encryption)
    partitioned = bool(curated) and all(token in curated[-1]["Key"] for token in ("event_year=", "event_month=", "event_day=", "event_hour="))
    add_control(controls, "FP-012", "Curated objects use event-time hour partitions", partitioned, curated[-1]["Key"] if curated else None)
    add_control(controls, "FP-013", "CloudWatch dashboard is retrievable", bool(dashboard.get("DashboardBody")), dashboard_name)
    add_control(controls, "FP-014", "Exactly four event-processing metric alarms are deployed", len(metric_alarms) == 4, metric_alarms)
    add_control(controls, "FP-015", "Exactly one composite health alarm is deployed", len(composite_alarms) == 1, composite_alarms)
    log_ready = len(log_groups) == 1 and log_groups[0].get("retentionInDays") == 30 and bool(log_groups[0].get("kmsKeyId"))
    add_control(controls, "FP-016", "Processor logging has 30-day retention and KMS encryption", log_ready, log_groups)
    alert_ready = alert_key.get("KeyManager") == "CUSTOMER" and alert_rotation.get("KeyRotationEnabled") is True
    add_control(controls, "FP-017", "Alert topic uses a rotating customer-managed key", alert_ready, {"key_arn": alert_key.get("Arn"), "rotation": alert_rotation.get("KeyRotationEnabled")})
    add_control(controls, "FP-018", "Processor S3 write permissions are prefix-scoped without s3:*", no_s3_wildcard_actions and object_writes_scoped, s3_statements)
    add_control(controls, "FP-019", "Custom operational metrics use the governed namespace", variables.get("METRIC_NAMESPACE") == "ZIPCO/FreePlanEvents", variables.get("METRIC_NAMESPACE"))
    workflow_ready = publisher.get("status") == "PUBLISHED_AND_PROCESSED" and replay.get("mode") == "DRY_RUN" and int(replay.get("records_selected", 0)) >= args.expected_valid + args.expected_invalid
    add_control(controls, "FP-020", "Publisher passed and replay dry run selected the complete batch", workflow_ready, {"publisher_status": publisher.get("status"), "replay_mode": replay.get("mode"), "replay_records": replay.get("records_selected")})

    passed = sum(control["status"] == "PASS" for control in controls)
    evidence = {
        "schema_version": "1.0.0",
        "status": "DEPLOYED_RUN_AND_VERIFIED" if passed == len(controls) else "VERIFICATION_FAILED",
        "deployment_variant": "free-plan-lambda-event-processing",
        "native_streaming_service": False,
        "generated_at": iso_now(),
        "region": args.region,
        "stack_name": args.stack_name,
        "run_id": args.run_id,
        "resources": {
            "processor_function": function_name,
            "processor_role": role_name,
            "bucket": args.bucket,
            "dashboard": dashboard_name,
            "alert_topic_arn": topic_arn,
            "alert_key_arn": alert_key.get("Arn"),
        },
        "delivery_observation": {
            "valid_sent": args.expected_valid,
            "invalid_sent": args.expected_invalid,
            "raw_records_observed": raw_count,
            "curated_records_observed": curated_count,
            "error_records_observed": error_count,
        },
        "publisher": publisher,
        "replay_dry_run": replay,
        "control_summary": {"passed": passed, "total": len(controls)},
        "controls": controls,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps(evidence, indent=2))
    return 0 if passed == len(controls) else 1


if __name__ == "__main__":
    raise SystemExit(main())
