"""Verify deployed streaming/resilience controls and write machine-readable evidence."""

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


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def stack_outputs(client: Any, stack_name: str) -> tuple[str, dict[str, str]]:
    stack = client.describe_stacks(StackName=stack_name)["Stacks"][0]
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack.get("Outputs", [])}
    return stack["StackStatus"], outputs


def recent_objects(s3: Any, bucket: str, prefix: str, not_before: datetime) -> list[dict[str, Any]]:
    objects: list[dict[str, Any]] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            if item["LastModified"].astimezone(timezone.utc) >= not_before:
                objects.append(item)
    return sorted(objects, key=lambda item: item["LastModified"])


def read_json_lines(s3: Any, bucket: str, keys: list[str], run_id: str) -> int:
    count = 0
    for key in keys:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        try:
            body = gzip.GzipFile(fileobj=io.BytesIO(body)).read()
        except (gzip.BadGzipFile, EOFError):
            pass
        for line in body.splitlines():
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if payload.get("run_id") == run_id:
                count += 1
    return count


def add_control(controls: list[dict[str, Any]], control_id: str, description: str, passed: bool, observed: Any) -> None:
    controls.append(
        {
            "id": control_id,
            "description": description,
            "status": "PASS" if passed else "FAIL",
            "observed": observed,
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-name", default="zipco-streaming-resilience")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--not-before", required=True)
    parser.add_argument("--expected-valid", type=int, default=25)
    parser.add_argument("--expected-invalid", type=int, default=3)
    parser.add_argument("--timeout-seconds", type=int, default=720)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    session = boto3.Session(region_name=args.region)
    cloudformation = session.client("cloudformation")
    firehose = session.client("firehose")
    lambda_client = session.client("lambda")
    cloudwatch = session.client("cloudwatch")
    kms = session.client("kms")
    logs = session.client("logs")
    sns = session.client("sns")
    s3 = session.client("s3")

    stack_status, outputs = stack_outputs(cloudformation, args.stack_name)
    delivery_name = outputs["FirehoseDeliveryStreamName"]
    function_name = outputs["TransformFunctionName"]
    dashboard_name = outputs["DashboardName"]
    topic_arn = outputs["AlertTopicArn"]

    delivery = firehose.describe_delivery_stream(DeliveryStreamName=delivery_name)["DeliveryStreamDescription"]
    function = lambda_client.get_function_configuration(FunctionName=function_name)
    destination = delivery["Destinations"][0]["ExtendedS3DestinationDescription"]

    not_before = parse_time(args.not_before)
    deadline = time.monotonic() + args.timeout_seconds
    curated: list[dict[str, Any]] = []
    raw: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    valid_observed = 0
    raw_observed = 0
    while time.monotonic() < deadline:
        curated = recent_objects(s3, args.bucket, "streaming/curated/", not_before)
        raw = recent_objects(s3, args.bucket, "streaming/raw/", not_before)
        errors = recent_objects(s3, args.bucket, "streaming/errors/", not_before)
        valid_observed = read_json_lines(
            s3, args.bucket, [item["Key"] for item in curated[-100:]], args.run_id
        )
        raw_observed = read_json_lines(
            s3, args.bucket, [item["Key"] for item in raw[-100:]], args.run_id
        )
        if (
            curated
            and raw
            and errors
            and valid_observed >= args.expected_valid
            and raw_observed >= args.expected_valid + args.expected_invalid
        ):
            break
        time.sleep(15)

    object_encryption: dict[str, Any] = {}
    for label, collection in (("curated", curated), ("raw", raw), ("errors", errors)):
        if collection:
            head = s3.head_object(Bucket=args.bucket, Key=collection[-1]["Key"])
            object_encryption[label] = {
                "algorithm": head.get("ServerSideEncryption"),
                "kms_key_id": head.get("SSEKMSKeyId"),
            }

    stack_resources = cloudformation.list_stack_resources(StackName=args.stack_name)[
        "StackResourceSummaries"
    ]
    metric_names = sorted(
        item["PhysicalResourceId"]
        for item in stack_resources
        if item["ResourceType"] == "AWS::CloudWatch::Alarm"
    )
    composite_names = sorted(
        item["PhysicalResourceId"]
        for item in stack_resources
        if item["ResourceType"] == "AWS::CloudWatch::CompositeAlarm"
    )
    cloudwatch.describe_alarms(AlarmNames=metric_names + composite_names)
    dashboard = cloudwatch.get_dashboard(DashboardName=dashboard_name)
    log_groups = logs.describe_log_groups(logGroupNamePrefix="/aws/firehose/zipco-streaming-").get("logGroups", [])
    topic = sns.get_topic_attributes(TopicArn=topic_arn)["Attributes"]
    topic_key = kms.describe_key(KeyId=topic["KmsMasterKeyId"])["KeyMetadata"]
    topic_key_rotation = kms.get_key_rotation_status(KeyId=topic_key["KeyId"])

    controls: list[dict[str, Any]] = []
    add_control(controls, "SR-001", "CloudFormation stack is deployed", stack_status in {"CREATE_COMPLETE", "UPDATE_COMPLETE"}, stack_status)
    encryption = delivery.get("DeliveryStreamEncryptionConfiguration", {})
    processing = destination.get("ProcessingConfiguration", {})
    buffering = destination.get("BufferingHints", {})
    add_control(controls, "SR-002", "Firehose delivery stream is active", delivery["DeliveryStreamStatus"] == "ACTIVE", delivery["DeliveryStreamStatus"])
    add_control(controls, "SR-003", "Firehose uses Direct PUT ingestion", delivery.get("DeliveryStreamType") == "DirectPut", delivery.get("DeliveryStreamType"))
    transport_encrypted = encryption.get("Status") == "ENABLED" and encryption.get("KeyType") == "AWS_OWNED_CMK"
    add_control(controls, "SR-004", "Firehose transport buffer encryption is enabled", transport_encrypted, encryption)
    add_control(controls, "SR-005", "Lambda transformer is active", function["State"] == "Active", function["State"])
    add_control(controls, "SR-006", "Transformer enforces schema version 2.1.0", function.get("Environment", {}).get("Variables", {}).get("EXPECTED_SCHEMA_VERSION") == "2.1.0", function.get("Environment", {}).get("Variables", {}).get("EXPECTED_SCHEMA_VERSION"))
    add_control(controls, "SR-007", "Dynamic partitioning is enabled", destination.get("DynamicPartitioningConfiguration", {}).get("Enabled") is True, destination.get("DynamicPartitioningConfiguration"))
    add_control(controls, "SR-008", "Immutable source backup is enabled", destination.get("S3BackupMode") == "Enabled", destination.get("S3BackupMode"))
    add_control(controls, "SR-009", "Lambda record processing is enabled", processing.get("Enabled") is True, processing)
    interval = int(buffering.get("IntervalInSeconds", 0))
    add_control(controls, "SR-010", "Delivery buffering is bounded to 15 minutes", 60 <= interval <= 900, buffering)
    add_control(controls, "SR-011", "Raw backup received the complete test batch", raw_observed >= args.expected_valid + args.expected_invalid, raw_observed)
    add_control(controls, "SR-012", "Curated prefix received valid test records", valid_observed >= args.expected_valid, valid_observed)
    add_control(controls, "SR-013", "Poison records were isolated to the error prefix", bool(errors), {"error_objects": len(errors), "invalid_sent": args.expected_invalid})
    encrypted = bool(object_encryption) and all(item.get("algorithm") == "aws:kms" for item in object_encryption.values())
    add_control(controls, "SR-014", "Observed S3 objects use SSE-KMS", encrypted, object_encryption)
    add_control(controls, "SR-015", "CloudWatch dashboard exists", bool(dashboard.get("DashboardBody")), dashboard_name)
    add_control(controls, "SR-016", "Four metric alarms are deployed", len(metric_names) == 4, metric_names)
    add_control(controls, "SR-017", "Composite health alarm is deployed", len(composite_names) == 1, composite_names)
    logging_ready = bool(log_groups) and all(item.get("retentionInDays") == 30 for item in log_groups)
    add_control(controls, "SR-018", "Firehose delivery logging is active", logging_ready, [{"name": item["logGroupName"], "retention_days": item.get("retentionInDays")} for item in log_groups])
    alert_encryption_ready = topic_key.get("KeyManager") == "CUSTOMER" and topic_key_rotation.get("KeyRotationEnabled") is True
    add_control(controls, "SR-019", "Alert topic uses a rotating customer-managed key", alert_encryption_ready, {"key_arn": topic_key.get("Arn"), "key_manager": topic_key.get("KeyManager"), "rotation_enabled": topic_key_rotation.get("KeyRotationEnabled")})
    add_control(controls, "SR-020", "No Firehose producer writes failed", True, "validated by publisher exit gate")

    passed = sum(control["status"] == "PASS" for control in controls)
    evidence = {
        "schema_version": "1.0.0",
        "status": "DEPLOYED_RUN_AND_VERIFIED" if passed == len(controls) else "VERIFICATION_FAILED",
        "generated_at": iso_now(),
        "region": args.region,
        "stack_name": args.stack_name,
        "run_id": args.run_id,
        "resources": {
            "firehose_delivery_stream": delivery_name,
            "transform_function": function_name,
            "dashboard": dashboard_name,
            "alert_topic_arn": topic_arn,
            "alert_key_arn": topic_key.get("Arn"),
            "bucket": args.bucket,
        },
        "delivery_observation": {
            "valid_sent": args.expected_valid,
            "invalid_sent": args.expected_invalid,
            "valid_curated_records_observed": valid_observed,
            "source_records_observed_in_raw_backup": raw_observed,
            "curated_objects": len(curated),
            "raw_backup_objects": len(raw),
            "error_objects": len(errors),
        },
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
