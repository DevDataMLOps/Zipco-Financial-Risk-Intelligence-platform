"""Inspect or replay bounded records from the Free-plan immutable S3 raw path."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from collections.abc import Iterable

import boto3


def records_from_bytes(body: bytes) -> Iterable[dict[str, object]]:
    try:
        body = gzip.GzipFile(fileobj=io.BytesIO(body)).read()
    except (gzip.BadGzipFile, EOFError):
        pass
    for line in body.splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            yield payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--prefix", default="streaming-free-plan/raw/")
    parser.add_argument("--function-name", required=True)
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--run-id", help="Only select records whose run_id matches")
    parser.add_argument("--max-records", type=int, default=100)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Invoke the processor; without this flag the command is a dry run",
    )
    args = parser.parse_args()
    if args.max_records < 1 or args.max_records > 500:
        parser.error("max-records must be between 1 and 500")

    s3 = boto3.client("s3", region_name=args.region)
    selected: list[dict[str, object]] = []
    objects_scanned = 0
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=args.bucket, Prefix=args.prefix):
        for item in page.get("Contents", []):
            objects_scanned += 1
            body = s3.get_object(Bucket=args.bucket, Key=item["Key"])["Body"].read()
            for payload in records_from_bytes(body):
                if args.run_id and payload.get("run_id") != args.run_id:
                    continue
                selected.append(payload)
                if len(selected) >= args.max_records:
                    break
            if len(selected) >= args.max_records:
                break
        if len(selected) >= args.max_records:
            break

    canonical = json.dumps(selected, separators=(",", ":"), sort_keys=True).encode("utf-8")
    replay_id = hashlib.sha256(canonical).hexdigest()[:16] if selected else None
    processor_response = None
    function_error = None
    if args.execute and selected:
        client = boto3.client("lambda", region_name=args.region)
        response = client.invoke(
            FunctionName=args.function_name,
            InvocationType="RequestResponse",
            Payload=json.dumps(
                {
                    "run_id": args.run_id or f"replay-{replay_id}",
                    "batch_id": f"replay-{replay_id}",
                    "source": "approved-replay",
                    "records": selected,
                },
                separators=(",", ":"),
            ).encode("utf-8"),
        )
        function_error = response.get("FunctionError")
        processor_response = json.loads(response["Payload"].read() or b"{}")

    passed = function_error is None
    print(
        json.dumps(
            {
                "mode": "EXECUTE" if args.execute else "DRY_RUN",
                "bucket": args.bucket,
                "prefix": args.prefix,
                "function_name": args.function_name,
                "objects_scanned": objects_scanned,
                "records_selected": len(selected),
                "replay_batch_id": replay_id,
                "function_error": function_error,
                "processor_response": processor_response,
            },
            indent=2,
        )
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
