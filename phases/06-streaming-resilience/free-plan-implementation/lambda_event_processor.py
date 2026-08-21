"""Process bounded ZIPCO event batches with Lambda and durable S3 recovery paths.

This is the Free-plan deployment variant. It deliberately uses direct Lambda
invocation instead of presenting Lambda as a native streaming service.
"""

from __future__ import annotations

import gzip
import json
import logging
import os
import re
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any

import boto3

from event_contract import RecordValidationError, normalize_record


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DATA_BUCKET = os.environ["DATA_BUCKET"]
KMS_KEY_ARN = os.environ["KMS_KEY_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "ZIPCO/FreePlanEvents")
PREFIX_ROOT = os.environ.get("PREFIX_ROOT", "streaming-free-plan")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def safe_token(value: Any) -> str:
    token = re.sub(r"[^A-Za-z0-9._-]", "-", str(value or "unknown"))
    return token[:128] or "unknown"


def ndjson_gzip(records: list[dict[str, Any]]) -> bytes:
    payload = "".join(
        json.dumps(record, separators=(",", ":"), default=str) + "\n"
        for record in records
    ).encode("utf-8")
    return gzip.compress(payload)


def put_records(s3: Any, key: str, records: list[dict[str, Any]]) -> None:
    if not records:
        return
    s3.put_object(
        Bucket=DATA_BUCKET,
        Key=key,
        Body=ndjson_gzip(records),
        ContentType="application/x-ndjson",
        ContentEncoding="gzip",
        ServerSideEncryption="aws:kms",
        SSEKMSKeyId=KMS_KEY_ARN,
        Metadata={"zipco-schema": "2.1.0", "zipco-data-classification": "internal"},
    )


def publish_metrics(cloudwatch: Any, function_name: str, accepted: int, rejected: int) -> None:
    dimensions = [{"Name": "FunctionName", "Value": function_name}]
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "AcceptedRecords", "Value": accepted, "Unit": "Count", "Dimensions": dimensions},
            {"MetricName": "RejectedRecords", "Value": rejected, "Unit": "Count", "Dimensions": dimensions},
            {"MetricName": "BatchFailures", "Value": 0, "Unit": "Count", "Dimensions": dimensions},
        ],
    )


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    records = event.get("records", [])
    if not isinstance(records, list) or not records:
        raise ValueError("records must be a non-empty list")
    if len(records) > 500:
        raise ValueError("a single batch cannot exceed 500 records")

    run_id = safe_token(event.get("run_id"))
    batch_id = safe_token(event.get("batch_id") or uuid.uuid4())
    now = utc_now()
    request_id = safe_token(getattr(context, "aws_request_id", batch_id))
    s3 = boto3.client("s3")
    cloudwatch = boto3.client("cloudwatch")

    raw_key = (
        f"{PREFIX_ROOT}/raw/ingest_year={now:%Y}/ingest_month={now:%m}/"
        f"ingest_day={now:%d}/ingest_hour={now:%H}/run_id={run_id}/batch_id={batch_id}.json.gz"
    )
    put_records(s3, raw_key, records)

    curated: dict[tuple[str, str, str, str], list[dict[str, Any]]] = defaultdict(list)
    rejected: list[dict[str, Any]] = []
    for payload in records:
        try:
            normalized, partition_keys = normalize_record(payload)
            normalized["source"] = "zipco-lambda-direct-invoke"
            key = (
                partition_keys["event_year"],
                partition_keys["event_month"],
                partition_keys["event_day"],
                partition_keys["event_hour"],
            )
            curated[key].append(normalized)
        except (RecordValidationError, TypeError, ValueError) as exc:
            failed = dict(payload) if isinstance(payload, dict) else {"raw_value": str(payload)}
            failed["_error_type"] = "contract_validation"
            failed["_error_message"] = str(exc)
            failed["_processed_at"] = now.isoformat().replace("+00:00", "Z")
            rejected.append(failed)

    curated_keys: list[str] = []
    for partition, grouped_records in curated.items():
        year, month, day, hour = partition
        key = (
            f"{PREFIX_ROOT}/curated/transactions/event_year={year}/event_month={month}/"
            f"event_day={day}/event_hour={hour}/run_id={run_id}/batch_id={batch_id}.json.gz"
        )
        put_records(s3, key, grouped_records)
        curated_keys.append(key)

    error_key = None
    if rejected:
        error_key = (
            f"{PREFIX_ROOT}/errors/error_type=contract_validation/event_year={now:%Y}/"
            f"event_month={now:%m}/event_day={now:%d}/event_hour={now:%H}/"
            f"run_id={run_id}/batch_id={batch_id}.json.gz"
        )
        put_records(s3, error_key, rejected)

    accepted_count = sum(len(group) for group in curated.values())
    function_name = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "zipco-free-plan-event-processor")
    publish_metrics(cloudwatch, function_name, accepted_count, len(rejected))
    summary = {
        "status": "PROCESSED",
        "run_id": run_id,
        "batch_id": batch_id,
        "request_id": request_id,
        "received": len(records),
        "accepted": accepted_count,
        "rejected": len(rejected),
        "raw_key": raw_key,
        "curated_keys": curated_keys,
        "error_key": error_key,
    }
    LOGGER.info(json.dumps({"event": "zipco_free_plan_batch_processed", **summary}, separators=(",", ":")))
    return summary
