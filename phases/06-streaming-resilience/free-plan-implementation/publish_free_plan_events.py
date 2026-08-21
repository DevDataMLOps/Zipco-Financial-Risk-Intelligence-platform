"""Invoke the ZIPCO Free-plan Lambda processor with deterministic test events."""

from __future__ import annotations

import argparse
import json
import random
import uuid
from datetime import datetime, timedelta, timezone

import boto3


TYPES = ("Deposit", "Withdrawal", "Transfer")


def make_event(run_id: str, index: int, event_time: datetime) -> dict[str, object]:
    rng = random.Random(f"{run_id}:{index}")
    return {
        "transaction_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"zipco:{run_id}:{index}")),
        "account_id": f"ACC-{rng.randrange(1, 150001):06d}",
        "customer_id": f"CUS-{rng.randrange(1, 100001):06d}",
        "event_time": event_time.isoformat().replace("+00:00", "Z"),
        "transaction_type": TYPES[index % len(TYPES)],
        "amount": f"{rng.uniform(1, 25000):.2f}",
        "currency": "USD",
        "schema_version": "2.1.0",
        "run_id": run_id,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--function-name", required=True)
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--valid-count", type=int, default=25)
    parser.add_argument("--invalid-count", type=int, default=3)
    args = parser.parse_args()
    if args.valid_count < 1 or args.invalid_count < 1:
        parser.error("valid-count and invalid-count must both be positive")

    now = datetime.now(timezone.utc).replace(microsecond=0)
    events = [make_event(args.run_id, i, now + timedelta(seconds=i)) for i in range(args.valid_count)]
    for i in range(args.invalid_count):
        poison = make_event(args.run_id, args.valid_count + i, now + timedelta(seconds=i))
        if i % 3 == 0:
            poison.pop("account_id")
        elif i % 3 == 1:
            poison["amount"] = "-1.00"
        else:
            poison["schema_version"] = "unsupported"
        poison["test_expected_outcome"] = "quarantine"
        events.append(poison)

    batch_id = f"verification-{args.run_id}"
    request = {
        "run_id": args.run_id,
        "batch_id": batch_id,
        "source": "cloudshell-test-publisher",
        "records": events,
    }
    client = boto3.client("lambda", region_name=args.region)
    response = client.invoke(
        FunctionName=args.function_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(request, separators=(",", ":")).encode("utf-8"),
    )
    payload = json.loads(response["Payload"].read() or b"{}")
    function_error = response.get("FunctionError")
    passed = (
        response.get("StatusCode") == 200
        and not function_error
        and payload.get("status") == "PROCESSED"
        and payload.get("accepted") == args.valid_count
        and payload.get("rejected") == args.invalid_count
    )
    summary = {
        "status": "PUBLISHED_AND_PROCESSED" if passed else "PROCESSING_FAILED",
        "function_name": args.function_name,
        "run_id": args.run_id,
        "valid_sent": args.valid_count,
        "invalid_sent": args.invalid_count,
        "http_status": response.get("StatusCode"),
        "function_error": function_error,
        "processor_response": payload,
    }
    print(json.dumps(summary, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
