"""ZIPCO schema-v2.1.0 validation shared by the Free-plan event processor."""

from __future__ import annotations

import os
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any


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
    """Raised when an event violates the governed contract."""


def parse_event_time(value: Any) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise RecordValidationError("event_time must be a non-empty RFC3339 string")
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
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
    if payload["transaction_type"] not in ALLOWED_TRANSACTION_TYPES:
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
    if payload["schema_version"] != EXPECTED_SCHEMA_VERSION:
        raise RecordValidationError("unsupported schema_version")
    event_time = parse_event_time(payload["event_time"])
    normalized = {
        "transaction_id": payload["transaction_id"].strip(),
        "account_id": payload["account_id"].strip(),
        "customer_id": payload["customer_id"].strip(),
        "event_time": event_time.isoformat().replace("+00:00", "Z"),
        "transaction_type": payload["transaction_type"],
        "amount": format(amount.quantize(Decimal("0.01")), "f"),
        "currency": currency.strip().upper(),
        "schema_version": EXPECTED_SCHEMA_VERSION,
        "run_id": payload["run_id"].strip(),
        "ingested_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    partition_keys = {
        "event_year": event_time.strftime("%Y"),
        "event_month": event_time.strftime("%m"),
        "event_day": event_time.strftime("%d"),
        "event_hour": event_time.strftime("%H"),
    }
    return normalized, partition_keys
