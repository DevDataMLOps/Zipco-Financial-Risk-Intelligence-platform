"""Validate, normalize, and partition ZIPCO streaming transaction events.

The handler follows the Amazon Data Firehose Lambda status model. Invalid
records are returned as ``ProcessingFailed`` so Firehose preserves them under
the configured S3 error prefix. No customer attributes are logged.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

EXPECTED_SCHEMA_VERSION = os.environ.get("EXPECTED_SCHEMA_VERSION", "2.1.0")
ALLOWED_TRANSACTION_TYPES = {"Deposit", "Withdrawal", "Transfer"}
REQUIRED_FIELDS = {
    "transaction_id",
    "account_id",
    "customer_id",
    "event_time",
    "transaction_type",
    "amount",
    "currency",
    "schema_version",
    "run_id",
}


class RecordValidationError(ValueError):
    """Raised when a record violates the streaming data contract."""


def parse_event_time(value: Any) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise RecordValidationError("event_time must be a non-empty RFC3339 string")
    candidate = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise RecordValidationError("event_time must be valid RFC3339") from exc
    if parsed.tzinfo is None:
        raise RecordValidationError("event_time must include a timezone")
    return parsed.astimezone(timezone.utc)


def normalize_record(payload: Any) -> tuple[dict[str, Any], dict[str, str]]:
    if not isinstance(payload, dict):
        raise RecordValidationError("record must be a JSON object")

    missing = sorted(REQUIRED_FIELDS.difference(payload))
    if missing:
        raise RecordValidationError(f"missing required fields: {','.join(missing)}")

    for field in ("transaction_id", "account_id", "customer_id", "run_id"):
        if not isinstance(payload[field], str) or not payload[field].strip():
            raise RecordValidationError(f"{field} must be a non-empty string")

    transaction_type = payload["transaction_type"]
    if transaction_type not in ALLOWED_TRANSACTION_TYPES:
        raise RecordValidationError("transaction_type is outside the governed domain")

    try:
        amount = Decimal(str(payload["amount"]))
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise RecordValidationError("amount must be numeric") from exc
    if not amount.is_finite() or amount <= 0 or amount > Decimal("1000000000"):
        raise RecordValidationError("amount must be greater than 0 and at most 1000000000")

    currency = payload["currency"]
    if not isinstance(currency, str) or len(currency.strip()) != 3:
        raise RecordValidationError("currency must be a three-letter code")
    currency = currency.strip().upper()

    if payload["schema_version"] != EXPECTED_SCHEMA_VERSION:
        raise RecordValidationError("unsupported schema_version")

    event_time = parse_event_time(payload["event_time"])
    normalized = {
        "transaction_id": payload["transaction_id"].strip(),
        "account_id": payload["account_id"].strip(),
        "customer_id": payload["customer_id"].strip(),
        "event_time": event_time.isoformat().replace("+00:00", "Z"),
        "transaction_type": transaction_type,
        "amount": format(amount.quantize(Decimal("0.01")), "f"),
        "currency": currency,
        "schema_version": EXPECTED_SCHEMA_VERSION,
        "run_id": payload["run_id"].strip(),
        "ingested_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": "zipco-firehose-direct-put",
    }
    partition_keys = {
        "event_year": event_time.strftime("%Y"),
        "event_month": event_time.strftime("%m"),
        "event_day": event_time.strftime("%d"),
        "event_hour": event_time.strftime("%H"),
    }
    return normalized, partition_keys


def handler(event: dict[str, Any], _context: Any) -> dict[str, list[dict[str, Any]]]:
    output: list[dict[str, Any]] = []
    accepted = 0
    rejected = 0

    for record in event.get("records", []):
        record_id = record.get("recordId", "missing-record-id")
        original_data = record.get("data", "")
        response: dict[str, Any] = {
            "recordId": record_id,
            "result": "ProcessingFailed",
            "data": original_data,
        }
        try:
            raw = base64.b64decode(original_data, validate=True).decode("utf-8").strip()
            payload = json.loads(raw)
            normalized, partition_keys = normalize_record(payload)
            encoded = (json.dumps(normalized, separators=(",", ":")) + "\n").encode("utf-8")
            response = {
                "recordId": record_id,
                "result": "Ok",
                "data": base64.b64encode(encoded).decode("ascii"),
                "metadata": {"partitionKeys": partition_keys},
            }
            accepted += 1
        except (RecordValidationError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
            rejected += 1
        output.append(response)

    LOGGER.info(
        json.dumps(
            {
                "event": "zipco_stream_batch_processed",
                "received": len(output),
                "accepted": accepted,
                "rejected": rejected,
            },
            separators=(",", ":"),
        )
    )
    return {"records": output}
